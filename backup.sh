#!/bin/bash
#
# MediaWiki backup and archiving script for installations on Linux using MySQL.
#
# https://github.com/samwilson/MediaWiki_Backup
#
# Copyright Sam Wilson 2013 CC-BY-SA
# http://creativecommons.org/licenses/by-sa/3.0/au/
# This work is a derivative of:
# - Initial bakup-mediawiki.sh script by xenlo (used under CC-BY-SA)
#   https://serom.eu/index.php/Backup_du_SeRoM_Wiki
# - Updated by mxmilkb (also used under CC-BY-SA)
#   https://github.com/mxmilkb/backup-mediawiki/blob/master/backup-mediawiki.sh
# - WikiBackup script by Megam0rf (still under CC-BY-SA)
#   https://www.mediawiki.org/wiki/User:Megam0rf/WikiBackup
# - Modified by Adnn, initial restore.sh script
#    https://github.com/Adnn/MediaWiki_Backup/
#


################################################################################
## Output command usage
function usage {
    local NAME=$(basename $0)
    echo "Usage: $NAME -d dir -w dir [-s] [-p prefix] [-f] [-c]"
    echo "       -d <dir>    Path to the desination backup directory. Required."
    echo "       -w <dir>    Path to the wiki installation directory. Required."
    echo "       -s          Create a single archive file instead of three"
    echo "                   (images, database, and XML). Optional."
    echo "       -p <prefix> Prefix for the resulting archive file name(s)."
    echo "                   Defaults to the current date in Y-m-d format. Optional."
    echo "       -f          Follow (dereference) symlinks for the 'images'"
    echo "                   directory. Optional."
    echo "       -c          Backup the complete wiki installation directory,"
    echo "                   not just the images. Optional."
    echo "       -h          Show this help message. Optional."
}

################################################################################
## Get and validate CLI options
function get_options {
    while getopts 'h:c:d:w:s:p:f' OPT; do
        case $OPT in
            h) usage; exit 1;;
            c) COMPLETE=true;;
            d) BACKUP_DIR=$OPTARG;;
            w) INSTALL_DIR=$OPTARG;;
            s) SINGLE_ARCHIVE=true;;
            p) PREFIX=$OPTARG;;
            f) DEREFERENCE_IMG=true;;
        esac
    done

    ## Check wiki installation directory
    if [ -z "$INSTALL_DIR" ]; then
        echo "Please specify the wiki directory with -w" 1>&2
        usage; exit 1;
    fi
    if [ ! -f "$INSTALL_DIR/LocalSettings.php" ]; then
        echo "No LocalSettings.php found in $INSTALL_DIR" 1>&2
        exit 1;
    fi
    INSTALL_DIR=$(cd $INSTALL_DIR; pwd -P)
    echo "Backing up wiki installed in $INSTALL_DIR"

    ## Check backup destination directory
    if [ -z "$BACKUP_DIR" ]; then
        echo "Please provide a backup directory with -d" 1>&2
        usage; exit 1;
    fi
    if [ ! -d "$BACKUP_DIR" ]; then
        mkdir --parents $BACKUP_DIR;
        if [ ! -d "$BACKUP_DIR" ]; then
            echo -n "Backup directory $BACKUP_DIR does not exist" 1>&2
            echo " and could not be created" 1>&2
            exit 1;
        fi
    fi
    BACKUP_DIR=$(cd "$BACKUP_DIR"; pwd -P)
    echo "Backing up to $BACKUP_DIR"

    ## Check and set the archive name prefix
    if [ -z "$PREFIX" ]; then
        PREFIX=$(date +%Y-%m-%d)
    fi

    ## Check whether a single archive file should be created
    if [ "$SINGLE_ARCHIVE" = true ]; then
        echo "Creating a single archive file"
    fi

    ## Dereference symlinks for the 'images' directory?
    if [ "$DEREFERENCE_IMG" = true ]; then
        echo "Symlinks will be followed for the 'images' directory"
    else
        echo "Symlinks will NOT be followed for the 'images' directory"
    fi
}

################################################################################
## Parse required values out of LocalSetttings.php
function get_localsettings_vars {
    LOCALSETTINGS="$INSTALL_DIR/LocalSettings.php"

    if [ ! -e $LOCALSETTINGS ];then
        echo "$LOCALSETTINGS file not found."
        return 1
    fi
    echo "Reading settings from $LOCALSETTINGS."

    DB_HOST=$(grep '^\$wgDBserver' $LOCALSETTINGS | cut -d\" -f2)
    DB_NAME=$(grep '^\$wgDBname' $LOCALSETTINGS  | cut -d\" -f2)
    DB_USER=$(grep '^\$wgDBuser' $LOCALSETTINGS  | cut -d\" -f2)
    DB_PASS=$(grep '^\$wgDBpassword' $LOCALSETTINGS  | cut -d\" -f2)
    echo "Logging in to MySQL as $DB_USER to $DB_HOST to backup $DB_NAME"

    # Try to extract default character set from LocalSettings.php
    # but default to binary
    DBTableOptions=$(grep '$wgDBTableOptions' $LOCALSETTINGS)
    DB_CHARSET=$(echo $DBTableOptions | sed -E 's/.*CHARSET=([^"]*).*/\1/')
    if [ -z $DB_CHARSET ]; then
        DB_CHARSET="binary"
    fi

    echo "Character set in use: $DB_CHARSET."
}

################################################################################
## Add $wgReadOnly to LocalSettings.php
## Kudos to http://www.mediawiki.org/wiki/User:Megam0rf/WikiBackup
function toggle_read_only {
    local MSG="\$wgReadOnly = 'Backup in progress.';"
    local LOCALSETTINGS="$INSTALL_DIR/LocalSettings.php"

    # Don't do anything if we can't write to LocalSettings.php
    if [ ! -w "$LOCALSETTINGS" ]; then
        echo "Cannot control read-only mode, aborting" 1>&2
        return 1
    fi

    # Verify if it is already read only
    grep "$MSG" "$LOCALSETTINGS" > /dev/null
    PRESENT=$?

    if [ $1 == "ON" ]; then
        if [ $PRESENT -ne 0 ]; then
            echo "Entering read-only mode"
            grep "?>" "$LOCALSETTINGS" > /dev/null
            if [ $? -eq 0 ];
            then
                sed -i "s/?>/\n$MSG/ig" "$LOCALSETTINGS"
            else
                echo "$MSG" >> "$LOCALSETTINGS"
            fi 
        else
            echo "Already in read-only mode"
        fi
    elif [ $1 == "OFF" ]; then
        # Remove read-only message
        if [ $PRESENT -eq 0 ]; then 
            echo "Returning to write mode"
            sed -i "s/$MSG//ig" "$LOCALSETTINGS"
        else
            echo "Already in write mode"
        fi
    fi
}

################################################################################
## Dump database to SQL
## Kudos to https://github.com/milkmiruku/backup-mediawiki
function export_sql {
    SQLFILE=$BACKUP_PREFIX"-database_$DB_CHARSET.sql.gz"
    echo "Dumping database to $SQLFILE"
    nice -n 19 mysqldump --single-transaction \
        --default-character-set=$DB_CHARSET \
        --host=$DB_HOST \
        --user=$DB_USER \
        --password=$DB_PASS \
        $DB_NAME | gzip -9 > $SQLFILE

    # Ensure dump worked
    MySQL_RET_CODE=$?
    if [ $MySQL_RET_CODE -ne 0 ]; then
        ERR_NUM=3
        echo "MySQL Dump failed! (return code of MySQL: $MySQL_RET_CODE)" 1>&2
        exit $ERR_NUM
    fi
    RUNNING_FILES="$RUNNING_FILES $SQLFILE"
}

################################################################################
## XML
## Kudos to http://brightbyte.de/page/MediaWiki_backup
function export_xml {
    XML_DUMP=$BACKUP_PREFIX"-pages.xml.gz"
    echo "Exporting XML to $XML_DUMP"
    cd "$INSTALL_DIR/maintenance"
    ## Make sure PHP is found.
    if hash php 2>/dev/null; then
        php -d error_reporting=E_ERROR dumpBackup.php \
            --conf="$INSTALL_DIR/LocalSettings.php" \
            --quiet --full --logs --uploads \
            | gzip -9 > "$XML_DUMP"

        RUNNING_FILES="$RUNNING_FILES $XML_DUMP"
    else
        echo "Error: Unable to find PHP; not exporting XML" 1>&2
    fi
}

################################################################################
## Export the images directory
function export_images {
    IMG_BACKUP=$BACKUP_PREFIX"-images.tar.gz"
    echo "Compressing images to $IMG_BACKUP"
    if [ -z "$DEREFERENCE_IMG" -a -h "$INSTALL_DIR/images" ]; then
        (>&2 echo "Warning: images directory is a symlink, but you have not elected to follow symlinks")
    fi
    if [ "$DEREFERENCE_IMG" = true ]; then
        DEREF="--dereference"
    else
        DEREF=""
    fi
    cd "$INSTALL_DIR"
    tar --create --exclude-vcs $DEREF --gzip --file "$IMG_BACKUP" images
    RUNNING_FILES="$RUNNING_FILES $IMG_BACKUP"
}


################################################################################
## Export the complete install directory
function export_filesystem {
    FS_BACKUP=$BACKUP_PREFIX"-filesystem.tar.gz"
    echo "Compressing install directory to $FS_BACKUP"
    tar --exclude-vcs -czhf "$FS_BACKUP" -C $INSTALL_DIR .
    RUNNING_FILES="$RUNNING_FILES $FS_BACKUP"
}


################################################################################
## Consolidate to one archive
function combine_archives {
    FULL_ARCHIVE=$BACKUP_PREFIX"-mediawiki-backup.tar.gz"
    echo "Consolidating backups into $FULL_ARCHIVE"
    # The --transform option is responsible for keeping the basename only
    tar -zcf "$FULL_ARCHIVE" $RUNNING_FILES --remove-files --transform='s|.*/||'
}


################################################################################
## Main

if [[ "$BASH_SOURCE" == "$0" ]];then

# Preparation
get_options $@
get_localsettings_vars
toggle_read_only ON

# Exports
RUNNING_FILES=
BACKUP_PREFIX=$BACKUP_DIR/$PREFIX
export_sql
export_xml

# Exports files from the installation directory. Which files are exported 
# depends on the command line arguments.
if [ "$COMPLETE" = true ]; then
    export_filesystem
else
    export_images
fi

toggle_read_only OFF

if [ "$SINGLE_ARCHIVE" = true ]; then
    combine_archives
fi

## End main
################################################################################
