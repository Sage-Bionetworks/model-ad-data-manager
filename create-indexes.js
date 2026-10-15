db = db.getSiblingDB("model-ad");

// An import builds its indexes on the staging collections, which are then
// renamed over the live collections, so the suffix is set to "_staging".
// Defaults to the live collection names when run by hand.
const suffix = process.env.COLLECTION_SUFFIX || "";

print("");
print('Creating indexes for "' + db.getName() + '"');
if (suffix) {
  print('Targeting collections with the "' + suffix + '" suffix');
}
print("");

const collation = { locale: "en", strength: 2 };

const collections = [
  {
    name: "model_details",
    indexes: [{ name: 1 }],
  },
  {
    name: "ui_config",
    indexes: [{ page: 1 }],
  },
  {
    name: "model_overview",
    collatedIndexes: [{ name: 1 }],
  },
  {
    name: "disease_correlation",
    indexes: [{ name: 1 }],
    collatedIndexes: [{ cluster: 1, name: 1, age: 1, sex: 1 }],
  },
  {
    name: "rna_de_aggregate",
    indexes: [{ ensembl_gene_id: 1 }],
    collatedIndexes: [
      { tissue: 1, ensembl_gene_id: 1, "name.link_text": 1, sex: 1 },
    ],
  },
  {
    name: "rna_de_individual",
    indexes: [
      { ensembl_gene_id: 1, tissue: 1, name: 1, model_group: 1 },
      { ensembl_gene_id: 1, model_group: 1, tissue: 1 },
    ],
  },
  {
    name: "marmo_details",
    indexes: [{ name: 1 }],
  },
  {
    name: "marmo_overview",
    indexes: [{ name: 1 }],
  },
  {
    name: "protein_de_aggregate",
    indexes: [{ unique_id: 1 }],
    collatedIndexes: [{ tissue: 1, unique_id: 1, "name.link_text": 1, sex: 1 }],
  },
  {
    name: "protein_de_individual",
    indexes: [
      { unique_id: 1, tissue: 1, name: 1, model_group: 1 },
      { unique_id: 1, model_group: 1, tissue: 1 },
    ],
  },
];

let results;

for (let collection of collections) {
  const name = collection.name + suffix;
  print("Collection: " + name);
  for (let index of collection.indexes || []) {
    print("Creating index...");
    printjson(index);
    results = db[name].createIndex(index);
    if (results && results.ok === 1) {
      print(
        results.numIndexesBefore < results.numIndexesAfter
          ? "Success!"
          : "Index already exists.",
      );
    } else {
      print("Failed: " + results.note ? results.note : "N/A");
    }
  }
  for (let index of collection.collatedIndexes || []) {
    print("Creating collated index...");
    printjson(index);
    results = db[name].createIndex(index, {
      collation: collation,
    });
    if (results && results.ok === 1) {
      print(
        results.numIndexesBefore < results.numIndexesAfter
          ? "Success!"
          : "Index already exists.",
      );
    } else {
      print("Failed: " + results.note ? results.note : "N/A");
    }
  }
  print("");
}
