#!/usr/bin/bash
#
# Extract an OCI artifact from the modctl cache directory

if [[ $# -ne 4 ]]; then
    >&2 echo "Wrong number of parameters"
    >&2 echo "modctl-to-oci.sh <model-name> <tag> <cache-dir> <destination-dir>"
    exit 1
fi

ARTIFACT=${1}
TAG=${2}
CACHE=${3}
DEST=${4}

rm -rf ${DEST}
mkdir ${DEST}

MODCTL_REGDIR=${CACHE}/content.v1/docker/registry/v2
REPODIR=${MODCTL_REGDIR}/repositories/${ARTIFACT}
BLOBDIR=${MODCTL_REGDIR}/blobs/sha256
TAGFILE=${REPODIR}/_manifests/tags/${TAG}/current/link
MANIFEST_ID=$(cat $TAGFILE)
MANIFEST=${BLOBDIR}/${MANIFEST_ID:7:2}/${MANIFEST_ID:7}/data
cp ${MANIFEST} ${DEST}/manifest.json
for DIGEST in `jq -M -r '.layers[] | .digest' ${MANIFEST}`
do
    cp ${BLOBDIR}/${DIGEST:7:2}/${DIGEST:7}/data ${DEST}/${DIGEST:7}
done
CONFIG=`jq -r .config.digest ${MANIFEST}`
cp ${BLOBDIR}/${CONFIG:7:2}/${CONFIG:7}/data ${DEST}/${CONFIG:7}
