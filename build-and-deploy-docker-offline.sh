#!/bin/bash

# command sample
# build-and-deploy-docker-offline -l docker-compose-build-prod.yml -f docker-compose.yml -o /home/epsi10n/docker-images-exported -r nl-sp-adp01 -u default -p default -d /home/default [...service_name]

USAGE_TEXT="Usage: build-and-deploy-docker-offline [-l,--local-compose-filename] [-f,--remote-compose-filename] [-o,--output-dir] [-r,--remote-host] [-u,--user] [-p,--password] [-d,--remote-dir] [SERVICE]..."
DISPLAY_HELP=0

# Step 0 - parse command-line options
POSITIONAL=()

LOCAL_COMPOSE_FILENAME="docker-compose.yml"
LOCAL_ENVS_DIR="envs"
REMOTE_COMPOSE_FILENAME="docker-compose.yml" 
IMAGES_OUTPUT_DIR="~/docker-images-exported"
REMOTE_HOST="localhost"
REMOTE_USER="default"
REMOTE_PASSWORD="default"
REMOTE_DIR="~"

while [[ $# -gt 0 ]]
do
    key="$1"
    case $key in
        -h|--help)
            DISPLAY_HELP=1
            shift
            shift
        ;;
        -l|--local-compose-filename)
            LOCAL_COMPOSE_FILENAME="$2"
            shift
            shift
        ;;
        -o|--output-dir)
            IMAGES_OUTPUT_DIR="$2"
            shift
            shift
        ;;
        -r|--remote-host)
            REMOTE_HOST="$2"
            shift
            shift
        ;;
        -u|--user)
            REMOTE_USER="$2"
            shift
            shift
        ;;
        -p|--password)
            REMOTE_PASSWORD="$2"
            shift
            shift
        ;;
        -d|--remote-dir)
            REMOTE_DIR="$2"
            shift
            shift
        ;;
        -f|--remote-compose-filename)
            REMOTE_COMPOSE_FILENAME="$2"
            shift
            shift
        ;;
        -e|--envs)
            LOCAL_ENVS_DIR="$2"
            shift
            shift
        ;;    
        *)   
            POSITIONAL+=" "
            POSITIONAL+=$1
            shift 
        ;;
    esac    
done

[[ $DISPLAY_HELP == 1 ]] && echo "$USAGE_TEXT" && exit 0

# Step 1 - searching for services
echo "Analyzing compose file..."
SERVICES="$(awk '/networks:/ { exit }; NR>2' $LOCAL_COMPOSE_FILENAME | grep "^  [^ ]*:" | awk '{ str = $1; sub(":", "", str); print str }')" # get all services for .yml file
# services to deploy (default - all)
TO_DEPLOY=()
# check positional (service names) arguments
for SRV_ARG in $POSITIONAL
do
    case $SERVICES in
        *"$SRV_ARG"*)
            TO_DEPLOY+=" "
            TO_DEPLOY+=$SRV_ARG
        ;;
    esac
done

# Step 2 - build artifacts 
echo "Building aftifacts..."
[[ ! -d $IMAGES_OUTPUT_DIR ]] && mkdir $IMAGES_OUTPUT_DIR && chmod +rwx $IMAGES_OUTPUT_DIR # create directory if not exists
docker-compose -f $LOCAL_COMPOSE_FILENAME build $TO_DEPLOY > "$IMAGES_OUTPUT_DIR/build.log"

# Step 3 - load artifacts on disk as tarball
IMAGES="$(grep "Successfully tagged" $IMAGES_OUTPUT_DIR/build.log | awk '{ print $3 }')"
rm $IMAGES_OUTPUT_DIR/build.log
for IMAGE in $IMAGES
do  
    echo "Saving $IMAGE..."
    IMAGE_FILE_NAME=$(echo $IMAGE | awk '{str = $1; gsub(".*/", "", str); gsub(":.*", "", str); print(str) }')
    IMAGE_FILE_PATH="$IMAGES_OUTPUT_DIR/$IMAGE_FILE_NAME.tar" 
    [[ -f $IMAGE_FILE_PATH ]] && rm $IMAGE_FILE_PATH # delete old tarball if exists
    docker save -o $IMAGE_FILE_PATH $IMAGE
    chmod +rwx $IMAGE_FILE_PATH
done

# Step 4 - deploy
# scan processes onto remote host and save it to temp file
TEMP_FILE="remote_ps.txt"
TEMP_SH_FILE_NAME="remote_deploy.sh"
TEMP_SH_FILE_PATH="$IMAGES_OUTPUT_DIR/$TEMP_SH_FILE_NAME"
[[ -f $TEMP_SH_FILE_PATH ]] && rm $TEMP_SH_FILE_PATH && touch $TEMP_SH_FILE_PATH && chmod +x $TEMP_SH_FILE_PATH
expect -c "spawn ssh $REMOTE_USER@$REMOTE_HOST \"sudo docker ps -a\"; expect \"assword:\"; send \"$REMOTE_PASSWORD\r\"; interact" | awk 'NR > 3' > "$IMAGES_OUTPUT_DIR/$TEMP_FILE"
# prepare remote cleanup script
for SRV in $TO_DEPLOY
do
    LINE=$(grep -w $SRV "$IMAGES_OUTPUT_DIR/$TEMP_FILE")
    echo $LINE | awk '{ print("docker stop", $1) }' >> $TEMP_SH_FILE_PATH
    echo $LINE | awk '{ print("docker rm", $1) }' >> $TEMP_SH_FILE_PATH
    echo $LINE | awk '{ print("docker rmi", $2) }' >> $TEMP_SH_FILE_PATH
done
rm "$IMAGES_OUTPUT_DIR/$TEMP_FILE"
# load new images
for IMAGE in $IMAGES
do
    echo $IMAGE | awk '{ str1 = "docker load -i "; str2 = $1; gsub(".*/", "", str2); gsub(":.*", "", str2); str3 = ".tar"; cmd = str1 str2 str3; print(cmd) }' >> $TEMP_SH_FILE_PATH
done
echo "docker-compose -f $REMOTE_COMPOSE_FILENAME up -d" >> $TEMP_SH_FILE_PATH
# copy local docker-compose.yml to output directory
cp $REMOTE_COMPOSE_FILENAME "$IMAGES_OUTPUT_DIR/$REMOTE_COMPOSE_FILENAME"
chmod +rx "$IMAGES_OUTPUT_DIR/$REMOTE_COMPOSE_FILENAME"
# copy envs directory
cp -R $LOCAL_ENVS_DIR "$IMAGES_OUTPUT_DIR/$LOCAL_ENVS_DIR"
chmod +rwx "$IMAGES_OUTPUT_DIR/$LOCAL_ENVS_DIR"
chmod +rwx $IMAGES_OUTPUT_DIR
# upload tarballs and remote shell script
lftp -e "cd $REMOTE_DIR; lcd $IMAGES_OUTPUT_DIR; mirror -R; exit" -u $REMOTE_USER,$REMOTE_PASSWORD sftp://$REMOTE_HOST
# run generated script remotely and remove it after success
REMOTE_SH_SCRIPT_PATH = "$REMOTE_DIR/$TEMP_SH_FILE_NAME"
expect -c "spawn ssh $REMOTE_USER@$REMOTE_HOST \"sudo $REMOTE_SH_SCRIPT_PATH && rm $REMOTE_SH_SCRIPT_PATH\"; expect \"assword:\"; send \"$REMOTE_PASSWORD\r\"; interact"
