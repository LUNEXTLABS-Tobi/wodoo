#!/bin/bash
# Basic Rules:
# - if a command would stop production run, then ask to continue is done before
#
# Important Githubs:
#   * https://github.com/docker/compose/issues/2293  -> /usr/local/bin/docker-compose needed
#   * there is a bug: https://github.com/docker/compose/issues/3352  --> using -T
#

set -e
set +x

args=("$@")
DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
ALL_PARAMS=${@:2} # all parameters without command


function default_confs() {
	export ODOO_FILES=$DIR/data/odoo.files
	export ODOO_UPDATE_START_NOTIFICATION_TOUCH_FILE=$DIR/run/update_started
	export RUN_POSTGRES=1
	export DB_PORT=5432
}

function export_customs_env() {
    # set variables from customs env
    while read line; do
        # reads KEY1=A GmbH and makes export KEY1="A GmbH" basically
        [[ "$line" == '#*' ]] && continue
        [[ "$line" == '' ]] && continue
        var="${line%=*}"
        value="${line##*=}"
        eval "$var=\"$value\""
    done <$DIR/customs.env
    export $(cut -d= -f1 $DIR/customs.env)  # export vars now in local variables
}

function restore_check() {
	set -x
	dumpname=$(basename $2)
	if [[ ! "${dumpname%.gz}" == "$DBNAME" ]]; then
		echo "The dump-name \"$dumpname\" should somehow match the current database \"$DBNAME\", which isn't."
		exit -1
	fi

}

function remove_postgres_connections() {
	echo "Removing all current connections"
	SQL=$(cat <<-EOF
		SELECT pg_terminate_backend(pg_stat_activity.pid)
		FROM pg_stat_activity 
		WHERE pg_stat_activity.datname = '$DBNAME' 
		AND pid <> pg_backend_pid(); 
		EOF
		)
	echo "$SQL" | $0 psql
}

function do_restore_db_in_docker_container () {
	# remove the postgres volume and reinit

	echo "Restoring dump within docker container postgres"
	dump_file=$1
	$dc kill
	$dc rm -f || true
	if [[ "$RUN_POSTGRES" == 1 ]]; then
		askcontinue "Removing docker volume postgres-data (irreversible)"
	fi
	VOLUMENAME=${PROJECT_NAME}_postgresdata
	docker volume ls |grep -q $VOLUMENAME && docker volume rm $VOLUMENAME 
	LOCAL_DEST_NAME=$DIR/restore/$DBNAME.gz
	[[ -f "$LOCAL_DEST_NAME" ]] && rm $LOCAL_DEST_NAME

	/bin/mkdir -p $DIR/restore
	/bin/ln $1 $LOCAL_DEST_NAME
	$0 reset-db
	$dc up -d postgres
	$dcrun postgres /restore.sh
}

function do_restore_db_on_external_postgres () {
	echo "Restoring dump on $DB_HOST"
	dump_file=$1
	echo "Using Host: $DB_HOST, Port: $DB_PORT, User: $DB_USER, ...."
	export PGPASSWORD=$DB_PWD
	ARGS="-h $DB_HOST -p $DB_PORT -U $DB_USER"
	PSQL="psql $ARGS"
	DROPDB="dropdb $ARGS"
	CREATEDB="createdb $ARGS"
	PGRESTORE="pg_restore $ARGS"

	remove_postgres_connections
	eval "$DROPDB $DBNAME" || echo "Failed to drop $DBNAME"
	eval "$CREATEDB $DBNAME"
	eval "$PGRESTORE -d $DBNAME $1" || {
		gunzip -c $1 | $PGRESTORE -d $DB
	}
}

function do_restore_files () {
	# remove the postgres volume and reinit
	tararchive_full_path=$1
	filename_oefiles=odoofiles.tar
	LOCAL_DEST_NAME=$DIR/restore/$filename_oefiles
	[[ -f "$LOCAL_DEST_NAME" ]] && rm $LOCAL_DEST_NAME

	/bin/ln $tararchive_full_path $LOCAL_DEST_NAME
	$dcrun odoo /bin/restore_files.sh $(basename $LOCAL_DEST_NAME)
}

function askcontinue() {
	echo $1
	if [[ "$ASK_CONTINUE" == "0" ]]; then
		if [[ -z "$1" ]]; then
			echo "Ask continue disabled, continueing..."
		fi
	else
		read -p "Continue? (Ctrl+C to break)" || {
			exit -1
		}
	fi
}

function showhelp() {
    echo Management of odoo instance
    echo
    echo
	echo ./manage.sh sanity-check
    echo Reinit fresh db:
    echo './manage.sh reset-db'
    echo
    echo Update:
    echo './manage.sh update [module]'
    echo 'Just custom modules are updated, never the base modules (e.g. prohibits adding old stock-locations)'
    echo 'Minimal downtime - but there is a downtime, even for phones'
    echo 
    echo "Please call manage.sh springclean|update|backup|run_standalone|upall|attach_running|rebuild|restart"
    echo "attach <machine> - attaches to running machine"
	echo ""
    echo "backup <backup-dir> - backup database and/or files to the given location with timestamp; if not directory given, backup to dumps is done "
	echo ""
    echo "backup-db <backup-dir>"
	echo ""
    echo "backup-files <backup-dir>"
	echo ""
    echo "debug <machine-name> - starts /bin/bash for just that machine and connects to it; if machine is down, it is powered up; if it is up, it is restarted; as command an endless bash loop is set"
	echo ""
    echo "build - no parameter all machines, first parameter machine name and passes other params; e.g. ./manage.sh build asterisk --no-cache"
	echo ""
    echo "clean_supportdata - clears support data"
	echo ""
    echo "install-telegram-bot - installs required python libs; execute as sudo"
	echo ""
    echo "telegram-setup- helps creating a permanent chatid"
	echo ""
    echo "kill - kills running machines"
	echo ""
    echo "logs - show log output; use parameter to specify machine"
	echo ""
    echo "logall - shows log til now; use parameter to specify machine"
	echo ""
    echo "make-CA - recreates CA caution!"
	echo ""
    echo "make-keys - creates VPN Keys for CA, Server, Asterisk and Client. If key exists, it is not overwritten"
	echo ""
    echo "springclean - remove dead containers, untagged images, delete unwanted volums"
	echo ""
    echo "rm - command"
	echo ""
    echo "rebuild - rebuilds docker-machines - data not deleted"
	echo ""
    echo "restart - restarts docker-machine(s) - parameter name"
	echo ""
    echo "restore <filepathdb> <filepath_tarfiles> [-force] - restores the given dump as odoo database"
	echo ""
    echo "restore-dev-db - Restores database dump regularly and then applies scripts to modify it, so it can be used for development (adapting mailserver, disable cronjobs)"
	echo ""
    echo "runbash <machine name> - starts bash in NOT RUNNING container (a separate one)"
	echo ""
    echo "setup-startup makes skript in /etc/init/${CUSTOMS}"
	echo ""
    echo "stop - like docker-compose stop"
	echo ""
    echo "quickpull - fetch latest source, oeln - good for mako templates"
	echo ""
    echo "update <machine name>- fetch latest source code of modules and run update of just custom modules; machines are restarted after that"
	echo ""
    echo "update-source - sets the latest source code in the containers"
	echo ""
    echo "up - starts all machines equivalent to service <service> start "
    echo
}

if [ -z "$1" ]; then
    showhelp
    exit -1
fi

function prepare_filesystem() {
    mkdir -p $DIR/run/config
}


function prepare_yml_files_from_template_files() {
    # replace params in configuration file
    # replace variables in docker-compose;
    cd $DIR
    echo "CUSTOMS: $CUSTOMS"
    echo "DB: $DBNAME"
    echo "VERSION: $ODOO_VERSION"
    echo "FILES: $ODOO_FILES"
    ALL_CONFIG_FILES=$(cd config; ls |grep '.*docker-compose\.*') 
    FILTERED_CONFIG_FILES=""
    for file in $ALL_CONFIG_FILES 
    do
        # check if RUN_ASTERISK=1 is defined, and then add it to the defined machines; otherwise ignore

        #docker-compose.odoo --> odoo
		RUN_X=$(
		python - <<-EOF
		print "RUN_" + "$file".replace("docker-compose.", "").split("-")[1].replace('.yml', '').replace("-", "_").upper()
		EOF
		)

        ENV_VALUE=${!RUN_X}  # variable indirection; get environment variable

        if [[ "$ENV_VALUE" == "" ]] || [[ "$ENV_VALUE" == "1" ]]; then

            FILTERED_CONFIG_FILES+=$file
            FILTERED_CONFIG_FILES+=','
            DEST_FILE=$DIR/run/$file
            cp config/$file $DEST_FILE
            sed -i -e "s/\${DCPREFIX}/$DCPREFIX/" -e "s/\${DCPREFIX}/$DCPREFIX/" $DEST_FILE
            sed -i -e "s/\${CUSTOMS}/$CUSTOMS/" -e "s/\${CUSTOMS}/$CUSTOMS/" $DEST_FILE
            sed -i -e "s|\${ODOO_FILES}|$ODOO_FILES|" -e "s|\${ODOO_FILES}|$ODOO_FILES|" $DEST_FILE
        fi
    done
    sed -e "s/\${ODOO_VERSION}/$ODOO_VERSION/" -e "s/\${ODOO_VERSION}/$ODOO_VERSION/" machines/odoo/Dockerfile.template > machines/odoo/Dockerfile

    all_config_files="$(for f in ${FILTERED_CONFIG_FILES//,/ }; do echo "-f run/$f"; done)"
    all_config_files=$(echo "$all_config_files"|tr '\n' ' ')
    dc="/usr/local/bin/docker-compose -p $PROJECT_NAME $all_config_files"
    dcrun="$dc run -T"
    dcexec="$dc exec -T"
}



function include_customs_conf_if_set() {
    # odoo customs can provide custom docker machines
    CUSTOMSCONF=$DIR/docker-compose-custom.yml
    if [[ -f "$CUSTOMSCONF" || -L "$CUSTOMSCONF" ]]; then
        echo "Including $CUSTOMSCONF"
        dc="$dc -f $CUSTOMSCONF"
    fi
}


function do_command() {
    case $1 in
    clean_supportdata)
        echo "Deleting support data"
        if [[ -d $DIR/support_data ]]; then
            /bin/rm -Rf $DIR/support_data/*
        fi
        ;;
    setup-startup)
        PATH=$DIR

        if [[ -f /sbin/initctl ]]; then
            # ubuntu 14.04 upstart
            file=/etc/init/${CUSTOMS}_odoo.conf

            echo "Setting up upstart script in $file"
            /bin/cp $DIR/config/upstart $file
            /bin/sed -i -e "s/\${DCPREFIX}/$DCPREFIX/" -e "s/\${DCPREFIX}/$DCPREFIX/" $file
            /bin/sed -i -e "s|\${PATH}|$PATH|" -e "s|\${PATH}|$PATH|" $file
            /bin/sed -i -e "s|\${CUSTOMS}|$CUSTOMS|" -e "s|\${CUSTOMS}|$CUSTOMS|" $file
            /sbin/initctl reload-configuration
        else
            echo "Setting up systemd script for startup"
            servicename=${CUSTOMS}_odoo.service
            file=/lib/systemd/system/$servicename

            echo "Setting up upstart script in $file"
            /bin/cp $DIR/config/systemd $file
            /bin/sed -i -e "s/\${DCPREFIX}/$DCPREFIX/" -e "s/\${DCPREFIX}/$DCPREFIX/" $file
            /bin/sed -i -e "s|\${PATH}|$PATH|" -e "s|\${PATH}|$PATH|" $file
            /bin/sed -i -e "s|\${CUSTOMS}|$CUSTOMS|" -e "s|\${CUSTOMS}|$CUSTOMS|" $file

            set +e
            /bin/systemctl disable $servicename
            /bin/rm /etc/systemd/system/$servicename
            /bin/rm lib/systemd/system/$servicename
            /bin/systemctl daemon-reload
            /bin/systemctl reset-failed
            /bin/systemctl enable $servicename
            /bin/systemctl start $servicename
        fi
        ;;
    exec)
        $dc exec $2 $3 $3 $4
        ;;
    backup_db)
        if [[ -n "$2" ]]; then
            BACKUPDIR=$2
        else
            BACKUPDIR=$DIR/dumps
        fi
        filename=$DBNAME.$(date "+%Y-%m-%d_%H%M%S").dump.gz
        filepath=$BACKUPDIR/$filename
        LINKPATH=$DIR/dumps/latest_dump
        $dc up -d postgres odoo
        # by following command the call is crontab safe;
        docker exec -i $($dc ps -q postgres) /backup.sh
        mv $DIR/dumps/$DBNAME.gz $filepath
        /bin/rm $LINKPATH || true
        ln -s $filepath $LINKPATH
        md5sum $filepath
        echo "Dumped to $filepath"
        ;;
    backup-files)
        if [[ -n "$2" ]]; then
            BACKUPDIR=$2
        else
            BACKUPDIR=$DIR/dumps
        fi
        BACKUP_FILENAME=oefiles.$CUSTOMS.tar
        BACKUP_FILEPATH=$BACKUPDIR/$BACKUP_FILENAME

		$dcrun odoo /backup_files.sh
        [[ -f $BACKUP_FILEPATH ]] && rm -Rf $BACKUP_FILEPATH
        mv $DIR/dumps/odoofiles.tar $BACKUP_FILEPATH

        echo "Backup files done to $BACKUPDIR/$filename_oefiles"
        ;;
    backup-db)
        if [[ -n "$2" ]]; then
            BACKUPDIR=$2
        else
            BACKUPDIR=$DIR/dumps
        fi

        $DIR/manage.sh backup_db $BACKUPDIR
		;;
    backup)
		$0 backup-db $ALL_PARAMS
		$0 backup-files $ALL_PARAMS

        ;;
    reset-db)
        [[ $last_param != "-force" ]] && {
            askcontinue "Deletes database $DBNAME!"
        }
		if [[ "$RUN_POSTGRES" != "1" ]]; then
			echo "Postgres container is disabled; cannot reset external database"
			exit -1
		fi
        echo "Stopping all services and creating new database"
        echo "After creation the database container is stopped. You have to start the system up then."
        $dc kill
        $dcrun -e INIT=1 postgres /entrypoint2.sh
        echo
        echo 
        echo
        echo "Database initialized. You have to restart now."

        ;;

    restore)

		restore_check $@

		echo "$*" |grep -q '-force' || {
			askcontinue "Deletes database $DBNAME!"
		}

        if [[ ! -f $2 ]]; then
            echo "File $2 not found!"
            exit -1
        fi
        if [[ -n "$3" && ! -f $3 ]]; then
            echo "File $3 not found!"
            exit -1
        fi

		dumpfile=$2
		tarfiles=$3
		
		if [[ "$tarfiles" == "-force" ]]; then
			tarfiles=""
		fi

		if [[ "$RUN_POSTGRES" == "1" ]]; then
			do_restore_db_in_docker_container $dumpfile
		else
			askcontinue "Trying to restore database on remote database. Please make sure, that the user $DB_USER has enough privileges for that."
			do_restore_db_on_external_postgres $dumpfile
		fi

        if [[ -n "$tarfiles" ]]; then
            echo 'Extracting files...'
			do_restore_files $tarfiles
        fi
		set_db_ownership

        echo "Restart systems by $0 restart"
        ;;
    restore-dev)
		if [[ "$ALLOW_RESTORE_DEV" ]]; then
			echo "ALLOW_RESTORE_DEV must be explicitly allowed."
			exit -1
		fi
        echo "Restores dump to locally installed postgres and executes to scripts to adapt user passwords, mailservers and cronjobs"
		set -x
		restore_check $@
		$0 ${@:1} || exit $? # keep restore and params
		exit -1

        SQLFILE=machines/postgres/turndb2dev.sql
		$0 psql < $SQLFILE

        ;;
	psql)
		# execute psql query

		sql=$(
		while read line
		do
			echo "$line"
		done < "${2:-/dev/stdin}"
		)

		if [[ "$RUN_POSTGRES" == "1" ]]; then
			$dcrun postgres psql $2
		else
			export PGPASSWORD=$DB_PWD
			echo "$sql" | psql -h $DB_HOST -p $DB_PORT -U $DB_USER -w $DBNAME
		fi 
		;;

    springclean)
        docker system prune

        echo removing dead containers
        docker rm $(docker ps -a -q)

        echo Remove untagged images
        docker images | grep "<none>" | awk '{ print "docker rmi " $3 }' | bash

        echo "delete unwanted volumes (can pass -dry-run)"
        docker rmi $(docker images -q -f='dangling=true')
        ;;
    up)
		set_db_ownership
        $dc up $ALL_PARAMS
        ;;
    debug)
		# puts endless loop into container command and then attaches to it;
		# by this, name resolution to the container still works
        if [[ -z "$2" ]]; then
            echo "Please give machine name as second parameter e.g. postgres, odoo"
            exit -1
        fi
		set_db_ownership
        echo "Current machine $2 is dropped and restartet with service ports in bash. Usually you have to type /debug.sh then."
        askcontinue
        # shutdown current machine and start via run and port-mappings the replacement machine
        $dc kill $2
        cd $DIR
		DEBUGGING_COMPOSER=$DIR/run/debugging.yml
		cp $DIR/config/debugging/template.yml $DEBUGGING_COMPOSER
		sed -i -e "s/\${DCPREFIX}/$DCPREFIX/" -e "s/\${NAME}/$2/" $DEBUGGING_COMPOSER
		dc="$dc -f $DEBUGGING_COMPOSER"  # command now has while loop

        #execute self
		$dc up -d $2
		$0 attach $2 

        ;;
    attach)
        if [[ -z "$2" ]]; then
            echo "Please give machine name as second parameter e.g. postgres, odoo"
            exit -1
        fi
        $dc exec $2 bash
        ;;
    runbash)
		set_db_ownership
        if [[ -z "$2" ]]; then
            echo "Please give machine name as second parameter e.g. postgres, odoo"
            exit -1
        fi
        $dc run $2 bash
        ;;
    rebuild)
        cd $DIR/machines/odoo
        cd $DIR
        eval "$dc build --no-cache $2"
        ;;
    build)
        cd $DIR
        eval "$dc build $ALL_PARAMS"
        ;;
    kill)
        cd $DIR
        eval "$dc kill $2 $3 $4 $5 $6 $7 $8 $9"
        ;;
    stop)
        cd $DIR
        eval "$dc stop $2 $3 $4"
        ;;
    logsn)
        cd $DIR
        eval "$dc logs --tail=$2 -f -t $3 $4"
        ;;
    logs)
        cd $DIR
        lines="${@: -1}"
        if [[ -n ${lines//[0-9]/} ]]; then
            lines="5000"
        else
            echo "Showing last $lines lines"
        fi
        eval "$dc logs --tail=$lines -f -t $2 "
        ;;
    logall)
        cd $DIR
        eval "$dc logs -f -t $2 $3"
        ;;
    rm)
        cd $DIR
        $dc rm $ALL_PARAMS
        ;;
    restart)
        cd $DIR
        eval "$dc kill $2"
        eval "$dc up -d $2"
        ;;
    install-telegram-bot)
        pip install python-telegram-bot
        ;;
	telegram-setup)
		echo
		echo 1. Create a new bot and get the Token
		read -p "Now enter the token [$TELEGRAMBOTTOKEN]:" token
		if [[ -z "$token" ]]; then
			token=$TELEGRAMBOTTOKEN
		fi
		if [[ -z "$token" ]]; then

			exit 0
		fi
		echo 2. Create a new public channel, add the bot as administrator and users
		read -p "Now enter the channel name with @:" channelname
		if [[ -z "$channelname" ]]; then
			exit 0
		fi
        python $DIR/bin/telegram_msg.py "__setup__" $token $channelname
		echo "Finished - chat id is stored; bot can send to channel all the time now."
		;;
    purge-source)
        $dcrun odoo rm -Rf /opt/openerp/customs/$CUSTOMS
        ;;
    update-source)
		$dcrun source_code /sync_source.sh $2
        ;;
    update)
        echo "Run module update"
		if [[ -n "$ODOO_UPDATE_START_NOTIFICATION_TOUCH_FILE" ]]; then
			date +%s > $ODOO_UPDATE_START_NOTIFICATION_TOUCH_FILE
		fi
        if [[ "$RUN_POSTGRES" == "1" ]]; then
        $dc up -d postgres
        fi
        $dc kill odoo_cronjobs # to allow update of cronjobs (active cronjob, cannot update otherwise)
        $dc kill odoo_update
        $dc rm -f odoo_update
        $dc up -d postgres && sleep 3

        set -e
        # sync source
        $dcrun source_code
        set +e

        $dcrun odoo_update /update_modules.sh $2
        $dc kill odoo nginx
        if [[ "$RUN_ASTERISK" == "1" ]]; then
            $dc kill ari stasis
        fi
        $dc kill odoo
        $dc rm -f
        $dc up -d
        python $DIR/bin/telegram_msg.py "Update done" &> /dev/null
        echo 'Removing unneeded containers'
        $dc kill nginx
        $dc up -d
        df -h / # case: after update disk / was full

       ;;
    make-CA)
        echo '!!!!!!!!!!!!!!!!!!'
        echo '!!!!!!!!!!!!!!!!!!'
        echo '!!!!!!!!!!!!!!!!!!'
        echo
        echo
        echo "Extreme Caution!"
        echo 
        echo '!!!!!!!!!!!!!!!!!!'
        echo '!!!!!!!!!!!!!!!!!!'
        echo '!!!!!!!!!!!!!!!!!!'

        askcontinue
        export dc=$dc
        $dc kill ovpn
        $dcrun ovpn_ca /root/tools/clean_keys.sh
        $dcrun ovpn_ca /root/tools/make_ca.sh
        $dcrun ovpn_ca /root/tools/make_server_keys.sh
        $dc rm -f
        ;;
    make-keys)
        export dc=$dc
        bash $DIR/config/ovpn/pack.sh
        $dc rm -f
        ;;
    export-i18n)
        LANG=$2
        MODULES=$3
        if [[ -z "$MODULES" ]]; then
            echo "Please define at least one module"
            exit -1
        fi
        rm $DIR/run/i18n/* || true
        chmod a+rw $DIR/run/i18n
        $dcrun odoo_lang_export /export_i18n.sh $LANG $MODULES
        # file now is in $DIR/run/i18n/export.po
        ;;
    import-i18n)
        $dcrun odoo /import_i18n.sh $ALL_PARAMS
        ;;
	sanity_check)
		sanity_check
		;;
    *)
        echo "Invalid option $1"
        exit -1
        ;;
    esac
}


function cleanup() {

    if [[ -f config/docker-compose.yml ]]; then
        /bin/rm config/docker-compose.yml || true
    fi
}

function sanity_check() {
    if [[ ( "$RUN_POSTGRES" == "1" || -z "$RUN_POSTGRES" ) && "$DB_HOST" != 'postgres' ]]; then
        echo "You are using the docker postgres container, but you do not have the DB_HOST set to use it."
        echo "Either configure DB_HOST to point to the docker container or turn it off by: "
        echo 
        echo "RUN_POSTGRES=0"
        exit -1
    fi

	if [[ -d $ODOO_FILES ]]; then
		if [[ "$(stat -c "%u" $ODOO_FILES)" != "1000" ]]; then
			echo "Changing ownership of $ODOO_FILES to 1000"
			chown 1000 $ODOO_FILES || {
				sudo !!
			}
		fi
	fi

	# make sure the odoo_debug.txt exists; otherwise directory is created
	if [[ ! -f "$DIR/run/odoo_debug.txt" ]]; then
		touch $DIR/run/odoo_debug.txt
	fi

	if [[ -z "ODOO_MODULE_UPDATE_DELETE_QWEB" ]]; then
		echo "Please define ODOO_MODULE_UPDATE_DELETE_QWEB"
		echo "Whenever modules are updated, then the qweb views are deleted."
		echo
		echo "Typical use for development environment."
		echo
		exit -1
	fi

	if [[ -z "ODOO_MODULE_UPDATE_RUN_TESTS" ]]; then
		echo "Please define wether to run tests on module updates"
		echo
		exit -1
	fi

	if [[ -z "$ODOO_CHANGE_POSTGRES_OWNER_TO_ODOO" ]]; then
		echo "Please define ODOO_CHANGE_POSTGRES_OWNER_TO_ODOO"
		echo In development environments it is safe to set ownership, so
		echo that accidently accessing the db fails
		echo
		exit -1
	fi
}

function set_db_ownership() {
	# in development environments it is safe to set ownership, so
	# that accidently accessing the db fails
	if [[ -n "$ODOO_CHANGE_POSTGRES_OWNER_TO_ODOO" ]]; then
		$dc up -d postgres
		$dcrun odoo bash -c "cd /opt/openerp/admin/module_tools; python -c\"from module_tools import set_ownership_exclusive; set_ownership_exclusive()\""
	fi
}

default_confs
export_customs_env
prepare_filesystem
prepare_yml_files_from_template_files
include_customs_conf_if_set
sanity_check
do_command "$@"
cleanup

