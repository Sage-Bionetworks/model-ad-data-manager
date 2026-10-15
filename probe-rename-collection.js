// TEMPORARY DIAGNOSTIC (MG-1171) - remove once the verdict is recorded.
//
// Answers one question against a real cluster: does this DocumentDB engine
// support renameCollection with dropTarget? MG-1171 wants to import each
// collection into <collection>_staging and then rename it over the live
// collection, which only works if dropTarget does.
//
// AWS documents renameCollection as supported on every instance-based engine
// version but says nothing about dropTarget, and MongoDB in Docker supports it
// regardless, so it cannot be answered anywhere but on the cluster itself.
//
// This script touches ONLY the two throwaway collections below. It never reads
// from or writes to a real collection. Run with:
//   mongosh "mongodb://<host>/model-ad?authSource=admin" \
//     --username <user> --password <pass> probe-rename-collection.js

db = db.getSiblingDB("model-ad");

const SOURCE = "mg1171_probe_source";
const TARGET = "mg1171_probe_target";

// Matches the collation create-indexes.js uses for its collated indexes
const collation = { locale: "en", strength: 2 };

const namespace = (name) => db.getName() + "." + name;

// Every line starts unanswered, so a crash can never read as a pass
const verdict = {
  "engine": "UNKNOWN",
  "helper renameCollection(target, true)": "NOT RUN",
  "adminCommand + dropTarget": "NOT RUN",
  "runCommand + dropTarget": "NOT RUN",
  "rename onto missing target": "NOT RUN",
  "rename without dropTarget (control)": "NOT RUN",
  "documents replaced (not merged)": "NOT RUN",
  "source collection removed": "NOT RUN",
  "indexes preserved (plain + collation)": "NOT RUN",
  "cleanup": "NOT RUN",
};

function describeError(e) {
  const code = e.code === undefined ? "?" : e.code;
  const codeName = e.codeName || e.name || "Error";
  return "FAILED code=" + code + " " + codeName + ": " + e.message;
}

// Two documents, a plain index, and a collation index on a different key.
// The collation index matters: MG-1171 builds indexes on the staging
// collection and relies on the rename carrying them across.
function seedSource() {
  db.getCollection(SOURCE).drop();
  db.getCollection(SOURCE).insertMany([
    { marker: "source", name: "alpha", label: "Alpha" },
    { marker: "source", name: "beta", label: "Beta" },
  ]);
  db.getCollection(SOURCE).createIndex({ name: 1 });
  db.getCollection(SOURCE).createIndex({ label: 1 }, { collation: collation });
}

// A marker document, so a rename that merges instead of replacing is visible
function seedTarget() {
  db.getCollection(TARGET).drop();
  db.getCollection(TARGET).insertOne({ marker: "target", name: "pre-existing" });
}

function commandResult(res) {
  return res && res.ok === 1 ? "SUPPORTED" : "FAILED " + JSON.stringify(res);
}

print("");
print("MG-1171 renameCollection dropTarget probe");
print('database: "' + db.getName() + '"');
print("probe collections: " + SOURCE + ", " + TARGET);
print("");

try {
  // Tie the verdict to a specific engine version
  try {
    const info = db.runCommand({ buildInfo: 1 });
    verdict["engine"] =
      (info.version || "unknown") +
      (info.versionArray ? " [" + info.versionArray.join(".") + "]" : "");
  } catch (e) {
    verdict["engine"] = describeError(e);
  }

  // Test 1: the mongosh shell helper, which is what an implementation would
  // normally call. Target already exists, so dropTarget has to do the work.
  print("Test 1: shell helper renameCollection(target, true)");
  try {
    seedSource();
    seedTarget();
    db.getCollection(SOURCE).renameCollection(TARGET, true);
    verdict["helper renameCollection(target, true)"] = "SUPPORTED";
  } catch (e) {
    verdict["helper renameCollection(target, true)"] = describeError(e);
  }

  // If the rename landed, check the two properties MG-1171 depends on:
  // it replaced rather than merged, and the indexes came across
  if (verdict["helper renameCollection(target, true)"] === "SUPPORTED") {
    try {
      const docs = db.getCollection(TARGET).find().toArray();
      const markers = docs.map((d) => d.marker);
      verdict["documents replaced (not merged)"] =
        docs.length === 2 && markers.indexOf("target") === -1
          ? "YES"
          : "NO (" + docs.length + " docs, markers=" + markers.join("/") + ")";

      verdict["source collection removed"] =
        db.getCollectionNames().indexOf(SOURCE) === -1 ? "YES" : "NO";

      const indexes = db.getCollection(TARGET).getIndexes();
      const hasPlain = indexes.some(
        (i) => i.key && i.key.name === 1 && !i.collation,
      );
      const hasCollated = indexes.some(
        (i) => i.key && i.key.label === 1 && i.collation,
      );
      verdict["indexes preserved (plain + collation)"] =
        hasPlain && hasCollated
          ? "YES"
          : "NO (" +
            indexes
              .map((i) => i.name + (i.collation ? "+collation" : ""))
              .join(", ") +
            ")";
    } catch (e) {
      verdict["documents replaced (not merged)"] = describeError(e);
    }
  }

  // Test 2: the raw admin command. Run even when test 1 passed, so a failure
  // of the helper can be told apart from the feature being unsupported - if
  // only this form works, the implementation can call it directly.
  print("Test 2: db.adminCommand({ renameCollection, dropTarget: true })");
  try {
    seedSource();
    seedTarget();
    verdict["adminCommand + dropTarget"] = commandResult(
      db.adminCommand({
        renameCollection: namespace(SOURCE),
        to: namespace(TARGET),
        dropTarget: true,
      }),
    );
  } catch (e) {
    verdict["adminCommand + dropTarget"] = describeError(e);
  }

  // Test 3: the same command on the non-admin database. MongoDB requires
  // adminCommand; DocumentDB has no admin database, so this may differ.
  print("Test 3: db.runCommand({ renameCollection, dropTarget: true })");
  try {
    seedSource();
    seedTarget();
    verdict["runCommand + dropTarget"] = commandResult(
      db.runCommand({
        renameCollection: namespace(SOURCE),
        to: namespace(TARGET),
        dropTarget: true,
      }),
    );
  } catch (e) {
    verdict["runCommand + dropTarget"] = describeError(e);
  }

  // Test 4: dropTarget against a target that does not exist, which is the
  // first-ever import into a brand new environment
  print("Test 4: rename onto a missing target");
  try {
    seedSource();
    db.getCollection(TARGET).drop();
    db.getCollection(SOURCE).renameCollection(TARGET, true);
    verdict["rename onto missing target"] =
      db.getCollection(TARGET).countDocuments() === 2
        ? "SUPPORTED"
        : "FAILED (target holds no documents after the rename)";
  } catch (e) {
    verdict["rename onto missing target"] = describeError(e);
  }

  // Test 5: control. Without dropTarget an existing target must be refused -
  // if this succeeds, the results above say nothing about dropTarget.
  print("Test 5: control, rename without dropTarget onto an existing target");
  try {
    seedSource();
    seedTarget();
    db.getCollection(SOURCE).renameCollection(TARGET);
    verdict["rename without dropTarget (control)"] =
      "UNEXPECTED SUCCESS - the target was replaced without dropTarget";
  } catch (e) {
    // Only NamespaceExists counts - any other error means the rename was
    // never attempted, so the control says nothing
    verdict["rename without dropTarget (control)"] =
      e.codeName === "NamespaceExists" || e.code === 48
        ? "REJECTED as expected (NamespaceExists)"
        : "INCONCLUSIVE - " + describeError(e);
  }
} finally {
  try {
    db.getCollection(SOURCE).drop();
    db.getCollection(TARGET).drop();
    const left = db
      .getCollectionNames()
      .filter((name) => name.indexOf("mg1171_probe_") === 0);
    verdict["cleanup"] =
      left.length === 0 ? "OK" : "LEFT BEHIND: " + left.join(", ");
  } catch (e) {
    verdict["cleanup"] = describeError(e);
  }

  const labels = Object.keys(verdict);
  const width = Math.max.apply(
    null,
    labels.map((label) => label.length),
  );

  print("");
  print("===== MG-1171 PROBE VERDICT =====");
  labels.forEach((label) => {
    print(label + ":" + " ".repeat(width - label.length) + "  " + verdict[label]);
  });
  print("=================================");
  print("");

  // An "unsupported" answer is a valid result, not a CI failure. Only a probe
  // that could not finish, or that left collections behind, fails the job.
  if (verdict["cleanup"] !== "OK") {
    print("Probe left collections behind - failing so they get cleaned up.");
    quit(1);
  }
  quit(0);
}
