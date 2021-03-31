#!/usr/bin/env bash
set -e

scriptDir=$( cd "$(dirname "${BASH_SOURCE}")" ; pwd -P )

VERSION_TO_UPDATE="all"
PHP_LAST_VERSION=$(find ./php/* -maxdepth 1 -prune -type d -exec basename {} \; | sort -n | tail -n 1)
NODE_LAST_VERSION=$(find ./php/$PHP_LAST_VERSION/node/* -maxdepth 1 -prune -type d -exec basename {} \; | sort -n | tail -n 1)

# Options
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
       echo "update.sh - update Dockerfile and scripts for all versions"
       echo " "
       echo "update.sh [options]"
       echo " "
       echo "options:"
       echo "-h, --help                show brief help"
       echo "-g, --generate=VERSION    VERSION is optional, all images config files are generated by default; set a VERSION like '7.2-node8'"
       echo "-b, --build=VERSION       VERSION is optional, all images are build by default; set a VERSION like '7.2-node8'"
       echo "-t, --test=VERSION        VERSION is optional, all images are tested by default; set a VERSION like '7.2-node8'"
       echo "--test-cached=VERSION     VERSION is required; set a VERSION like '7.2-node8'"
       echo "--clean"                  clean all local tags of the imahe
       exit 0
       ;;
    -g|--generate*)
      VERSION_TO_UPDATE="${1#*=}"
      if [ "$1" = "--build" ] || [ "$1" = "-b" ]; then
        VERSION_TO_UPDATE="all"
      fi
      ;;
    -b|--build*)
      VERSION_TO_BUILD="${1#*=}"
      if [ "$1" = "--build" ] || [ "$1" = "-b" ]; then
        VERSION_TO_BUILD="all"
      fi
      VERSION_TO_UPDATE=$VERSION_TO_BUILD
      ;;
    --test-cached=*)
      VERSION_TO_TEST="${1#*=}"
      VERSION_TO_UPDATE=$VERSION_TO_TEST
      VERSION_TO_BUILD="none"
      ;;
    -t|--test*)
      VERSION_TO_TEST="${1#*=}"
      if [ "$1" = "--test" ] || [ "$1" = "-t" ]; then
        VERSION_TO_TEST="all"
      fi
      VERSION_TO_UPDATE=$VERSION_TO_TEST
      VERSION_TO_BUILD=$VERSION_TO_TEST
      VERSION_TO_TEST=$VERSION_TO_TEST
      ;;
    --clean)
      if [ ! -z "$(docker images | grep antistatique/php-dev | tr -s ' ' | cut -d ' ' -f 2 | grep -v '<none>')" ]; then
        docker images | grep antistatique/php-dev | tr -s ' ' | cut -d ' ' -f 2 | grep -v '<none>' | xargs -I {} docker rmi antistatique/php-dev:{}
      fi
      echo "** images cleanded"
      exit 0
      ;;
  esac
  shift
done

# functions

function tag {
  if [ "$1" = "latest" ]; then
    echo "latest"
  elif [ ! -z "$2" ]; then
    echo "$1-node$2"
  else
    echo "$1"
  fi
}

function build {
  (
    set -e
    TAG=$(tag $1 $2)

    echo "** build antistatique/php-dev:$TAG"
    if [ -z "$2" ]; then
      cd ${scriptDir}/php/$1/
    else
      cd ${scriptDir}/php/$1/node/$2/
    fi
    docker build --pull -t antistatique/php-dev:$TAG .
  )
}

function test {
  (
    set -e
    TAG=$(tag $1 $2)

    echo "** test antistatique/php-dev:$TAG"
    if [ -z "$2" ]; then
      cd ${scriptDir}/php/$1/
    else
      cd ${scriptDir}/php/$1/node/$2/
    fi

    # Ensure base metadata.
    container-structure-test test --image antistatique/php-dev:${TAG} --config ${scriptDir}/tests/baseMetadataTests.yaml

    # Ensure base file existences.
    container-structure-test test --image antistatique/php-dev:${TAG} --config ${scriptDir}/tests/baseFileExistenceTests.yaml

    # Ensure base commands.
    container-structure-test test --image antistatique/php-dev:${TAG} --config ${scriptDir}/tests/baseCommandTests.yaml

    # Image specific structure testing.
    if [ -z "$2" ]; then
      container-structure-test test --image antistatique/php-dev:${TAG} --config ${scriptDir}/php/$1/tests/config--${TAG}.yaml
    else
      container-structure-test test --image antistatique/php-dev:${TAG} --config ${scriptDir}/php/$1/node/$2/tests/config--${TAG}.yaml
    fi
  )
}

function process {
  phpVersion=$1
  nodeVersion=$2
  tag=$(tag $1 $2)

  if [ "$VERSION_TO_UPDATE" != "all" ] && [ "$VERSION_TO_UPDATE" != "$tag" ]; then
    return
  fi

  echo "** update files for php-dev:$tag"

  if [ -z "$nodeVersion" ]; then
    DOCKERFILE_PATH=${scriptDir}/php/$phpVersion/Dockerfile
  else
    DOCKERFILE_PATH=${scriptDir}/php/$phpVersion/node/$nodeVersion/Dockerfile
  fi
  DOCKERFILE_DIR=$(dirname $DOCKERFILE_PATH)

  mkdir -p $DOCKERFILE_DIR/scripts

  # cleanup removed scripts
  for file in `diff <(cd ${scriptDir}/scripts; find . -type f | sort) <(cd $DOCKERFILE_DIR/scripts; find .  -type f | sort) | grep "^>" | awk -F/ '{print "'"$DOCKERFILE_DIR/scripts/"'" $2}'`; do
    (
      set -e

      git rm -f -q --ignore-unmatch $file
      rm -f $file
      echo "removed $file"
    )
  done

  # copy scripts
  cp ${scriptDir}/scripts/* $DOCKERFILE_DIR/scripts/
  chmod 774 $DOCKERFILE_DIR/scripts/*

  # copy Dockerfile
  sed \
    -e "s!%%PHP_VERSION%%!${phpVersion}!g" \
    -e "s!%%NODE_VERSION%%!${nodeVersion:-"false"}!g" \
    ./Dockerfile > "$DOCKERFILE_PATH"

  # build docker imge if required
  if [ "$VERSION_TO_BUILD" = "all" ] || [ "$VERSION_TO_BUILD" = "$tag" ]; then
    build $phpVersion $nodeVersion
  fi

  # test docker imge if required
  if [ "$VERSION_TO_TEST" = "all" ] || [ "$VERSION_TO_TEST" = "$tag" ]; then
    test $phpVersion $nodeVersion
  fi
}


# Go through versions
for phpVersion in `find ./php/* -maxdepth 1 -prune -type d -exec basename {} \; | sort -n`; do
  process $phpVersion
  for nodeVersion in `find ./php/$phpVersion/node/* -maxdepth 1 -prune -type d -exec basename {} \; | sort -n`; do
    process $phpVersion $nodeVersion
  done
done

# tag latest version
if [ "$VERSION_TO_BUILD" = "all" ] || [ "$VERSION_TO_BUILD" = "$PHP_LAST_VERSION-node$NODE_LAST_VERSION" ]; then
  docker tag antistatique/php-dev:$PHP_LAST_VERSION-node$NODE_LAST_VERSION antistatique/php-dev:latest
fi
