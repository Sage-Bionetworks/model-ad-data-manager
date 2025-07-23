# This script gets data from synapse then imports the data to an model-ad DB.
# This script needs to be run from an model-ad bastian machine, it assumes that
# the bastian is already setup with synapse, mongoimport and mongofiles
# command line clients
#!/bin/bash
set -e

BRANCH=$1
SYNAPSE_PASSWORD=$2
DB_HOST=$3
DB_USER=$4
DB_PASS=$5

CURRENT_DIR=$(pwd)
WORKING_DIR=$CURRENT_DIR
DATA_DIR=$WORKING_DIR/data

mkdir -p $DATA_DIR

# Version key/value should be on his own line
DATA_VERSION=$(cat $WORKING_DIR/data-manifest.json | grep data_version | head -1 | awk -F: '{ print $2 }' | sed 's/[",]//g' | tr -d '[[:space:]]')
DATA_FILE=$(cat $WORKING_DIR/data-manifest.json | grep data_file | head -1 | awk -F: '{ print $2 }' | sed 's/[",]//g' | tr -d '[[:space:]]')
echo "$BRANCH branch, DATA_VERSION = $DATA_VERSION, manifest id = $DATA_FILE"

# Download the manifest file from synapse
synapse -p $SYNAPSE_PASSWORD get --downloadLocation $DATA_DIR -v $DATA_VERSION $DATA_FILE

# Ensure there's a newline at the end of the manifest file; otherwise the last listed file will not be downloaded
# echo >> $DATA_DIR/data_manifest.csv

# Download all files referenced in the manifest from synapse
cat $DATA_DIR/data_manifest.csv | tail -n +2 | while IFS=, read -r id version; do
  echo Downloading $id,$version
    synapse -p $SYNAPSE_PASSWORD get --downloadLocation $DATA_DIR -v $version $id ;
  done

echo "Data Files: "
ls -al $WORKING_DIR
ls -al $DATA_DIR

# Check if dataversion exists and handle different data format
DATAVERSION_PATH="${DATA_DIR}/dataversion.json"
DATAVERSION_FLAG="--jsonArray"
if [ ! -f "${DATAVERSION_PATH}" ]; then
  DATAVERSION_PATH="${WORKING_DIR}/data-manifest.json"
  DATAVERSION_FLAG=""
fi

# Import synapse data to database
# Not using --mode upsert for now because we don't have unique indexes properly set for the collections

mongoimport -h $DB_HOST -d model-ad -u $DB_USER -p $DB_PASS --authenticationDatabase admin --collection model_details --jsonArray --drop --file $DATA_DIR/model_details.json
mongoimport -h $DB_HOST -d model-ad -u $DB_USER -p $DB_PASS --authenticationDatabase admin --collection ui_config --jsonArray --drop --file $DATA_DIR/ui_config.json
mongoimport -h $DB_HOST -d model-ad -u $DB_USER -p $DB_PASS --authenticationDatabase admin --collection model_overview --jsonArray --drop --file $DATA_DIR/model_overview.json
mongoimport -h $DB_HOST -d model-ad -u $DB_USER -p $DB_PASS --authenticationDatabase admin --collection disease_correlation --jsonArray --drop --file $DATA_DIR/disease_correlation.json

echo "Importing dataversion from ${DATAVERSION_PATH}"
mongoimport -h $DB_HOST -d model-ad -u $DB_USER -p $DB_PASS --authenticationDatabase admin --collection dataversion $DATAVERSION_FLAG --drop --file $DATAVERSION_PATH

mongosh --host $DB_HOST -u $DB_USER -p $DB_PASS --authenticationDatabase admin $WORKING_DIR/create-indexes.js
