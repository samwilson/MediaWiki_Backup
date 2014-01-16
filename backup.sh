#!/bin/bash
#
# MediaWiki backup and archiving script for installations on Linux using MySQL.
#
# Copyright Sam Wilson 2013 CC-BY-SA
# http://samwilson.id.au/public/MediaWiki
#
# Modified by Adrien D 2013-2014
#


################################################################################
## Output command usage
function usage {
    local NAME=$(basename $0)
    cat << EOF
Usage: $NAME -d backup/dir -w installation/dir -c

OPTIONS:
    -h	Show this message
    -d  The directory where the backup will be written to
    -w  The wiki installation directory
    -c  Make an archive with the content of the whole installation directory, instead of just the 'images' directory
EOF
}

################################################################################
## Get and validate CLI options
COMPLETE=

function get_options {
    while getopts 'hcd:w:' OPT; do
        case $OPT in
            h) usage; exit 1;;
            c) COMPLETE=1;;
            d) BACKUP_DIR=$OPTARG;;
            w) INSTALL_DIR=$OPTARG;;
        esac
    done

    ## Check WIKI_WEB_DIR
    if [ -z $INSTALL_DIR ]; then
        echo "Please specify the wiki directory with -w" 1>&2
        usage; exit 1;
    fi
    if [ ! -f $INSTALL_DIR/LocalSettings.php ]; then
        echo "No LocalSettings.php found in $INSTALL_DIR" 1>&2
        exit 1;
    fi
    INSTALL_DIR=$(cd $INSTALL_DIR; pwd -P)
    echo "Backing up wiki installed in $INSTALL_DIR"

    ## Check BKP_DIR
    if [ -z $BACKUP_DIR ]; then
        echo "Please provide a backup directory with -d" 1>&2
        usage; exit 1;
    fi
    if [ ! -d $BACKUP_DIR ]; then
        mkdir --parents $BACKUP_DIR;
        if [ ! -d $BACKUP_DIR ]; then
            echo -n "Backup directory $BACKUP_DIR does not exist" 1>&2
            echo " and could not be created" 1>&2
            exit 1;
        fi
    fi
    BACKUP_DIR=$(cd $BACKUP_DIR; pwd -P)
    echo "Backing up to $BACKUP_DIR"

}

################################################################################
## Parse required values out of LocalSetttings.php
function get_localsettings_vars {
    LOCALSETTINGS="$INSTALL_DIR/LocalSettings.php"

    DB_HOST=`grep '^\$wgDBserver' $LOCALSETTINGS | cut -d\" -f2`
    DB_NAME=`grep '^\$wgDBname' $LOCALSETTINGS  | cut -d\" -f2`
    DB_USER=`grep '^\$wgDBuser' $LOCALSETTINGS  | cut -d\" -f2`
    DB_PASS=`grep '^\$wgDBpassword' $LOCALSETTINGS  | cut -d\" -f2`

    # Try to extract default character set from LocalSettings.php
    # but default to binary
    DBTableOptions=$(grep '$wgDBTableOptions' $LOCALSETTINGS)
    DB_CHARSET=$(echo $DBTableOptions | sed -E 's/.*DB_CHARSET=([^"]*).*/\1/')
    if [ -z $DB_CHARSET ]; then
        DB_CHARSET="binary"
    fi

    echo "Character set in use: $DB_CHARSET"
}

################################################################################
## Add $wgReadOnly to LocalSettings.php
## Kudos to http://www.mediawiki.org/wiki/User:Megam0rf/WikiBackup
function toggle_read_only {
    local MSG="\$wgReadOnly = 'Backup in progress.';"
    local LOCALSETTINGS="$INSTALL_DIR/LocalSettings.php"

    # Verify if it is already read only
    grep "$MSG" "$LOCALSETTINGS" > /dev/null
    PRESENT=$?

    if [ $1 -eq "ON" ]; then
        if [ $PRESENT -ne 0 ]; then
            echo "Entering read-only mode"
            grep "?>" "$LOCALSETTINGS" > /dev/null
            if [ $? -eq 0 ];
            then
                sed -i "s/?>/\n$MSG/ig" "$LOCALSETTINGS"
            else
                echo "$MSG" >> "$LOCALSETTINGS"
            fi 
        elif
            echo "Already in read-only mode"
        fi
    elif [ $1 -eq "OFF" ]; then
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
    php -d error_reporting=E_ERROR dumpBackup.php --quiet --full \
    | gzip -9 > "$XML_DUMP"
    RUNNING_FILES="$RUNNING_FILES $XML_DUMP"
}

################################################################################
## Export the images directory
function export_images {
    IMG_BACKUP=$BACKUP_PREFIX"-images.tar.gz"
    echo "Compressing images to $IMG_BACKUP"
    cd "$INSTALL_DIR"
    tar --exclude-vcs -zcf "$IMG_BACKUP" images
    RUNNING_FILES="$RUNNING_FILES $IMG_BACKUP"
}

################################################################################
## Export the install directory
function export_filesystem {
    FS_BACKUP=$BACKUP_PREFIX"-filesystem.tar.gz"
    echo "Compressing install directory to $FS_BACKUP"
    tar --exclude-vcs -czhf "$FS_BACKUP" -C $INSTALL_DIR .
    RUNNING_FILES="$RUNNING_FILES $FS_BACKUP"
}

################################################################################
## Consolidate to one archive
function consolidate_archives {
    SINGLE_ARCHIVE=$BACKUP_PREFIX"-mediawiki.tar.gz"
    echo "Consolidating backups into $SINGLE_ARCHIVE"
    # The --transform option is responsible for keeping the basename only
    tar -zcf "$SINGLE_ARCHIVE" $RUNNING_FILES --remove-files --transform='s|.*/||'
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
BACKUP_PREFIX=$BACKUP_DIR/$(date +%Y-%m-%d)
export_sql
export_xml

# Exports files from the installation directory. Which files are exported 
# depends on the command line arguments.
if [ -n "$COMPLETE" ]; then
    export_filesystem
else
    export_images
fi

consolidate_archives

toggle_read_only OFF

fi #End sourcing guard
## End main
################################################################################

# eh? what's this do? exec > /dev/null
