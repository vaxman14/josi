#!/bin/bash
# Pull the published v6-b36 image and build v6-b37 on it with the beta.37 Josi package (copy /tmp/Dockerfile.b37 -> Dockerfile.update first).
# Used on the build machine 2026-11-18. Then: docker tag, docker push to Docker Hub (needs docker login) and public.ecr.aws/g3p9e4y8/josi-allinone.
set -eu
umask 022
export DOCKER_CONFIG=$HOME/josi-linux/docker-anon
D=$HOME/josi-linux/aio-b37
REL=$HOME/JosiDrive/BuildTemp/josi-ce-native-linux-20261010/releases/1.2.8-beta.37
mkdir -p $D
cp "$(dirname "$0")/Dockerfile.update" $D/Dockerfile
ln -f $REL/josi_1.2.8-beta.37_amd64.deb $D/ 2>/dev/null || cp $REL/josi_1.2.8-beta.37_amd64.deb $D/
(cd $REL && sha256sum -c SHA256SUMS.txt --ignore-missing 2>&1 | grep amd64)
echo "== pull $(date +%T)"
docker pull -q romanvaxman/josi-allinone:v6-b36
echo "== build $(date +%T)"
docker build -t josi-allinone:v6-b37 $D 2>&1 | tail -15
docker image ls josi-allinone:v6-b37
docker history --format '{{.Size}}  {{.CreatedBy}}' josi-allinone:v6-b37 | head -4 | cut -c1-110
echo "== ALL DONE $(date +%T)"
