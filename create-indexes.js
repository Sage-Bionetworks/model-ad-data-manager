db = db.getSiblingDB('model-ad')

print('');
print('Creating indexes for "' + db.getName() + '"');
print('');

const collections = [
    {
        name: 'model_details',
        indexes: [
            { name: 1 },
        ]
    },
    {
        name: 'ui_config',
        indexes: [
            { page: 1 },
        ]
    },
    {
        name: 'model_overview',
        indexes: [
            { name: 1 },
        ]
    },
    {
        name: 'disease_correlation',
        indexes: [
            { name: 1 },
            { cluster: 1, name: 1, age: 1, sex: 1 },
        ]
    },
    {
        name: "rna_de_aggregate",
        indexes: [
            { ensembl_gene_id: 1 },
            { tissue: 1, sex: 1, ensembl_gene_id: 1, name: 1 },
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
