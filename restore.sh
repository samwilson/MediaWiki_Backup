#!/bin/bash
#
# MediaWiki restoration script for backups made using backup.sh
#
# Copyright Adrien D 2014 CC-BY-SA
#

################################################################################
## Includes backup.sh to get access to its functions
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
. $DIR/backup.sh

################################################################################
## Output command usage
function usage_restore {
    local NAME=$(basename $0)
    cat << EOF
Usage: $NAME -a backup-archive -w installation/dir [-p mysql-password [-d] [-u]]

OPTIONS:
    -h  Show this message.
    -a  The archive containing the backup.
    -w  The wiki installation directory where the backup should be restored.
    -p  The MySQL root password.
    -d  Recreate the wiki MySQL database, based on the DB name found in the backup archive.
    -u  Recreate the wiki MySQL user, based on the user found in the backup archive.
EOF
}

################################################################################
## Get and validate CLI options

function get_options {
    RESTORE_USER=
    RESTORE_DB=

    while getopts 'hdua:w:p:' OPT; do
        case $OPT in
            h) usage_restore; exit 1;;
            d) RESTORE_DB=1;;
            u) RESTORE_USER=1;;
            a) ARCHIVE_FILE=$OPTARG;;
            w) INSTALL_DIR=$OPTARG;;
            p) MYSQL_ROOT_PWD=$OPTARG;;
        esac
    done

    ## Check WIKI_WEB_DIR
    if [ -z $INSTALL_DIR ]; then
        echo "Please specify the wiki directory with -w" 1>&2
        usage_restore; exit 1;
    fi
    if [ ! -d $INSTALL_DIR ]; then
        mkdir --parents $INSTALL_DIR;
        if [ ! -d $INSTALL_DIR ]; then
            echo "Wiki installation directory does not exist and cannot be created" 1>&2
            exit 1;
        fi
    fi
    
    ## Check BKP_DIR
    if [ -z $ARCHIVE_FILE ]; then
        echo "Please provide an archive file -a" 1>&2
        usage_restore; exit 1;
    fi
    if [ ! -f $ARCHIVE_FILE ]; then
        echo "Backup archive $ARCHIVE_FILE does not exist" 1>&2
        exit 1;
    fi
}

################################################################################
## MySQL wiki database and user creation

function execute_sql {
    SQL_STATEMENT=$1
    echo "Executing statement : '$SQL_STATEMENT'"
    echo $SQL_STATEMENT | mysql -u root --password=$MYSQL_ROOT_PWD --host=$DB_HOST 
}
  
function restore_database {
    execute_sql "create database $DB_NAME;"
}

#Information taken from here http://www.mediawiki.org/wiki/Manual:Installation/Creating_system_accounts
#Compared to show grants for '$user'@host, which showed that 'WITH GRANT OPTION' was not set by the original installation in version 1.17
# \note the % system is any IP, but does not work for localhost ! see http://stackoverflow.com/questions/10823854/using-for-host-when-creating-a-mysql-user
function restore_user {
    execute_sql "grant all privileges on $DB_NAME.* to $DB_USER@localhost.localdomain identified by '$DB_PASS';"
    execute_sql "grant all privileges on $DB_NAME.* to $DB_USER@localhost identified by '$DB_PASS';"
    execute_sql "grant all privileges on $DB_NAME.* to $DB_USER@'%' identified by '$DB_PASS';"
}

################################################################################
## Database restoration
function restore_database_content {
    if [ -z $DB_NAME ]; then
        echo "No database was found, cannot restore sql dump."
        return 1
    fi

    echo "Restoring database '$DB_NAME' from file $SQLFILE" 
    gunzip -c $SQLFILE | mysql -u root --password=$MYSQL_ROOT_PWD --host=$DB_HOST $DB_NAME
}

################################################################################
## Filesystem restoration
function restore_filesystem {
    echo "Extracting filesystem from $FS_BACKUP"
    tar -xzf "$FS_BACKUP" -C "$INSTALL_DIR"
}

################################################################################
## Images restoration
function restore_images {
    echo "Extracting images from $IMG_BACKUP"
    tar -xzf "$IMG_BACKUP" -C "$INSTALL_DIR"
}

################################################################################
## Getting the archive date
function retrieve_archive_info {
    ARCHIVE_DATE=${ARCHIVE_BASENAME%-*}
    BACKUP_PREFIX=$TMP_DIR/$ARCHIVE_DATE

    echo "Restoring archive $ARCHIVE_BASENAME dated of $ARCHIVE_DATE."    

    # Analyze the filesystem restoration options
    FS_BACKUP=$BACKUP_PREFIX"-filesystem.tar.gz"
    if [ ! -e $FS_BACKUP ]; then
        FS_BACKUP=
    fi

    # Analyze the images restoration options
    IMG_BACKUP=$BACKUP_PREFIX"-images.tar.gz"
    if [ ! -e $IMG_BACKUP ]; then
        IMG_BACKUP=
    fi

    # Analyze DB restoration options
    SQLFILE=$TMP_DIR/$(ls $TMP_DIR |grep "database"|head -1)
    _ENDSQL=${SQLFILE##*_}
    ARCHIVE_DB_CHARSET=${_ENDSQL%%.*}
    echo "SQL dump $(basename "$SQLFILE") found, with charset $ARCHIVE_DB_CHARSET."
}

################################################################################
## Archive expansion and clean-up
function expand_single_archive {
    ARCHIVE_BASENAME=$(basename "$ARCHIVE_FILE")
    TMP_DIR="/tmp/"${ARCHIVE_BASENAME%%.*}
    mkdir -p "$TMP_DIR"
    tar -xzf "$ARCHIVE_FILE" -C "$TMP_DIR"
}

function cleanup_archive_expansion {
    rm -r "${TMP_DIR}"
}

################################################################################
################################################################################
if [[ "$BASH_SOURCE" == "$0" ]];then

get_options "$@"
## First restores the filesystem archive
## This will allow us to access LocalSettings.php
expand_single_archive
retrieve_archive_info

if [ -n "$FS_BACKUP" ]; then
    restore_filesystem
else
    echo "No filesystem archive was found."
    if [ -n "$IMG_BACKUP" ]; then
        restore_images
    else
        echo "No image archive was found."
    fi
fi

## It is now possible to try reading LocalSettings.php
get_localsettings_vars

if [ -n "$RESTORE_DB" ];then
    restore_database
fi
if [ -n "$RESTORE_USER" ];then
    restore_user
fi

restore_database_content

# The backup procedure would save LocalSettings in read-only mode
toggle_read_only OFF

cleanup_archive_expansion

fi # end sourcing guard
