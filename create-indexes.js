db = db.getSiblingDB('model-ad')

print('');
print('Creating indexes for "' + db.getName() + '"');
print('');

const collections = [
    {
        name: 'modeldetails',
        indexes: [
            { model: 1 },
        ]
    },
    {
        name: 'uiconfig',
        indexes: [
            { page: 1 },
        ]
    }
];

let results;

for (let collection of collections) {
    print('Collection: ' + collection.name);
    for (let index of collection.indexes) {
        print('Creating index...');
        printjson(index);
        results = db[collection.name].createIndex(index);
        if (results && results.ok === 1) {
            print(results.numIndexesBefore < results.numIndexesAfter ? 'Success!' : 'Index already exists.');
        }
        else {
            print('Failed: ' + results.note ? results.note : 'N/A');
        }
    }
    print('');
}
