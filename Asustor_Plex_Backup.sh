#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2181
#--------------------------------------------------------------------------
# Backup Asustor NAS Plex Database to tgz file in Backup folder.
# v1.6.0  05-Feb-2023  007revad
#
#   MUST be run by a user in sudo, sudoers or wheel group, or as root
#
# To run the script:
# sudo -i /volume1/scripts/backup_asustor_plex_to_tar.sh
#   Change /volume1/scripts/ to the path where this script is located
#
# To do a test run on just Plex's profiles folder run:
# sudo -i /volume1/scripts/backup_asustor_plex_to_tar.sh test
#   Change /volume1/scripts/ to the path where this script is located
#
# Github: https://github.com/007revad/Asustor_Plex_Backup
# Script verified at https://www.shellcheck.net/
#--------------------------------------------------------------------------
# REQUIRED:
# Because the Asustor only has BusyBox this script needs bash installed.
#
# Install Entware from App Central, then run the following commands via SSH
# You can run the commands in "Shell In A Box" from App Central, or use PuTTY
#   opkg update && opkg upgrade
#   opkg install bash
#--------------------------------------------------------------------------


# Changes
# Added restore_asustor_plex.sh script.
# Changed to abort if not running in bash.
# Changed /volume1/Plex to /share/Plex in case Asustor allow installing Plex on different volume in future
# Improved checking if Plex has stopped.


#--------------------------------------------------------------------------

# Process Expansion and redirecting stdout and stderr to separate Log and 
# Error Log causes an error on Asustor NAS unless bash is installed.
# Check if script is running in GNU bash and not BusyBox ash

Shell=$(/proc/self/exe --version 2>/dev/null | grep "GNU bash" | cut -d "," -f1)
if [ "$Shell" != "GNU bash" ]; then
    echo -e "\nYou need to install bash to be able to run this script.\n"
    echo "1. Install Entware from App Central"
    echo "2. Run the following commands in a shell:"
    echo "opkg update && opkg upgrade"
    echo -e "opkg install bash\n"
    exit 1
fi


# Read variables from backup_asustor_plex.config
if [[ -f $(dirname -- "$0";)/backup_asustor_plex.config ]];then
    source $(dirname -- "$0";)/backup_asustor_plex.config
else
    echo "backup_asustor_plex.config file missing!"
    exit 1
fi


# Check if backup directory exists
if [[ ! -d $Backup_Directory ]]; then
    echo "Backup directory not found:"
    echo "$Backup_Directory"
    echo "Check your setting in backup_asustor_plex.config"
    exit 1
fi


#--------------------------------------------------------------------------
# Set date and time variables

# Timer variable to log time taken to backup PMS
start="${SECONDS}"

# Get Start Time and Date
Started=$( date )

# Get Today's date for filename
Now=$( date '+%Y%m%d')
# Get Today's date and time for filename in case filename exists
NowLong=$( date '+%Y%m%d-%H%M')


#--------------------------------------------------------------------------
# Set NAS name (used in backup and log filenames)

case "${Name,,}" in
    brand)
        # Get NAS Brand
        if [[ -f /etc/nas.conf ]]; then
            Nas="$(awk '/^Vendor\s/{print $3}' /etc/nas.conf)"
        fi
        ;;
    model)
        # Get Asustor model
        if [[ -f /etc/nas.conf ]]; then
            Nas="$(awk '/^Model\s/{print $3}' /etc/nas.conf)"
        fi
        ;;
    hostname|"")
        # Get Hostname
        Nas=$( hostname )
        ;;
    *)
        # Set Nas to nickname
        Nas="$Name"
        ;;
esac


#--------------------------------------------------------------------------
# Set temporary log filenames (we get the Plex version later)

# Set backup filename
Backup_Name="${Nas}"_"${Now}"_Plex_"${Version}"_Backup

# If file exists already include time in name
BackupPN="$Backup_Directory/$Backup_Name"
if [[ -f $BackupPN.tgz ]] || [[ -f $BackupPN.log ]] || [[ -f "$BackupPN"_ERROR.log ]]; then
    Backup_Name="${Nas}"_"${NowLong}"_Plex_"${Version}"_Backup
fi

# Set log filename
Log_File="${Backup_Directory}"/"${Backup_Name}".log

# Set error log filename
Err_Log_File="${Backup_Directory}"/"${Backup_Name}"_ERROR.log


#--------------------------------------------------------------------------
# Create temp error log

# Asustor mktemp only accepts max 6 Xs

# Create temp directory for temp error log
Tmp_Dir=$(mktemp -d -t plex_to_tar-XXXXXX)

# Create temp error log
Tmp_Err_Log_File=$(mktemp "${Tmp_Dir}"/errorlog-XXXXXX)


#--------------------------------------------------------------------------
# Create trap and clean up function

# Tmp logs clean up function
cleanup() {
    arg1=$?
    # Move tmp_error_log to error log if tmp_error_log is not empty
    if [[ -s $Tmp_Err_Log_File ]] && [[ -d $Backup_Directory ]]; then
        mv "${Tmp_Err_Log_File}" "${Err_Log_File}"
        if [[ $? -gt "0" ]]; then
            echo "WARNING Failed moving ${Tmp_Err_Log_File} to ${Err_Log_File}"\
                |& tee -a "${Err_Log_File}"
        fi
    fi
    # Delete our tmp directory
    if [[ -d $Tmp_Dir ]]; then
        rm -rf "${Tmp_Dir}"
        if [[ $? -gt "0" ]]; then
            echo "WARNING Failed deleting ${Tmp_Dir}" |& tee -a "${Err_Log_File}"
        fi
    fi

    if [[ $Version ]]; then Version="${Version} "; fi

    # Log and notify of success or errors
    if [[ -f $Err_Log_File ]]; then
        # Log and notify backup had errors
        if [[ ! -f $Log_File ]]; then
            # Add script name to top of log file
            basename -- "$0" |& tee -a "${Log_File}"
        fi
        echo -e "\n\e[41mWARNING\e[0m Plex backup had errors! See error log:"
        echo -e "\nWARNING Plex backup had errors! See error log:" >> "${Log_File}"
        echo -e "$(basename -- ${Err_Log_File})\n" |& tee -a "${Log_File}"

        # Add entry to Asustor system log
        if [[ ${Brand,,} == "asustor" ]] && [[ ${SysLog,,} == "yes" ]]; then
            syslog --log 0 --level 0 --user "$( whoami )" --event "Plex ${Version}backup had errors. See ERROR.log"
        fi
    else
        # Log and notify of backup success
        echo -e "\nPlex backup completed successfully" |& tee -a "${Log_File}"

        # Add entry to Asustor system log
        if [[ ${Brand,,} == "asustor" ]] && [[ ${SysLog,,} == "yes" ]]; then
            syslog --log 0 --level 0 --user "$( whoami )" --event "Plex ${Version}backup completed successfully."
        fi
    fi
    exit "${arg1}"
}

trap cleanup EXIT


#--------------------------------------------------------------------------
# Check that script is running as root

if [[ $( whoami ) != "root" ]]; then
    if [[ -d $Backup_Directory ]]; then
        echo "ERROR: This script must be run as root!" |& tee -a "${Tmp_Err_Log_File}"
        echo "ERROR: $( whoami ) is not root. Aborting." |& tee -a "${Tmp_Err_Log_File}"
    else
        # Can't log error to log file because $Backup_Directory does not exist
        echo -e "\nERROR: This script must be run as root!"
        echo -e "ERROR: $( whoami ) is not root. Aborting.\n"
    fi
    # Add entry to Asustor system log
    if [[ ${Brand,,} == "asustor" ]] && [[ ${SysLog,,} == "yes" ]]; then
        syslog --log 0 --level 1 --user "$( whoami )" --event "Plex backup failed. Needs to run as root."
    fi
    # Abort script because it isn't being run by root
    exit 255
fi


#--------------------------------------------------------------------------
# Check script is running on an Asustor NAS

if [[ -f /etc/nas.conf ]]; then Brand="$(awk '/^Vendor\s/{print $3}' /etc/nas.conf)"; fi
# Returns: ASUSTOR

if [[ ${Brand,,} != "asustor" ]]; then
    if [[ -d $Backup_Directory ]]; then
        echo "Checking script is running on a Asustor NAS" |& tee -a "${Tmp_Err_Log_File}"
        echo "ERROR: $(hostname) is not a Asustor! Aborting." |& tee -a "${Tmp_Err_Log_File}"
    else
        # Can't log error to log file because $Backup_Directory does not exist
        echo -e "\nChecking script is running on a Asustor NAS"
        echo -e "ERROR: $( hostname ) is not a Asustor! Aborting.\n"
    fi
    # Can't Add entry to Asustor system log because script not running on an Asustor
    # Abort script because it's being run on the wrong NAS brand
    exit 255
fi


#--------------------------------------------------------------------------
# Find Plex Media Server location

# Set the Plex Media Server data location
Plex_Data_Path=/share/Plex/Library


#--------------------------------------------------------------------------
# Check Plex Media Server data path exists

if [[ ! -d $Plex_Data_Path ]]; then
    echo "Plex Media Server data path invalid! Aborting." |& tee -a "${Tmp_Err_Log_File}"
    echo "${Plex_Data_Path}" |& tee -a "${Tmp_Err_Log_File}"
    if [[ ${Brand,,} == "asustor" ]] && [[ ${SysLog,,} == "yes" ]]; then
        # Add entry to Asustor system log
        syslog --log 0 --level 1 --user "$( whoami )" --event "Plex backup failed. Plex data path invalid."
    fi
    # Abort script because Plex data path invalid
    exit 255
fi


#--------------------------------------------------------------------------
# Get Plex Media Server version

Version="$(/usr/local/AppCentral/plexmediaserver/Plex\ Media\ Server --version)"
# Returns v1.29.2.6364-6d72b0cf6
# Plex version without v or hex string
Version=$(printf %s "${Version:1}"| cut -d "-" -f1)
# Returns 1.29.2.6364


#--------------------------------------------------------------------------
# Re-assign log names to include Plex version

# Backup filename
Backup_Name="${Nas}"_"${Now}"_Plex_"${Version}"_Backup

# If file exists already include time in name
BackupPN="$Backup_Directory/$Backup_Name"
if [[ -f $BackupPN.tgz ]] || [[ -f $BackupPN.log ]] || [[ -f "$BackupPN"_ERROR.log ]]; then
    Backup_Name="${Nas}"_"${NowLong}"_Plex_"${Version}"_Backup
fi

# Log file filename
Log_File="${Backup_Directory}"/"${Backup_Name}".log

# Error log filename
Err_Log_File="${Backup_Directory}"/"${Backup_Name}"_ERROR.log


#--------------------------------------------------------------------------
# Start logging

# Log NAS brand, model, DSM version and hostname
Model="$(awk '/^Model\s/{print $3}' /etc/nas.conf)"
ADMversion="$(awk '/^Version\s/{print $3}' /etc/nas.conf)"
echo "${Brand}" "${Model}" ADM "${ADMversion}" |& tee -a "${Log_File}"
echo "Hostname: $( hostname )" |& tee -a "${Log_File}"

# Log Plex version
echo Plex version: "${Version}" |& tee -a "${Log_File}"


#--------------------------------------------------------------------------
# Check if backup directory exists

if [[ ! -d $Backup_Directory ]]; then
    echo "ERROR: Backup directory not found! Aborting backup." |& tee -a "${Log_File}" "${Tmp_Err_Log_File}"
    if [[ ${Brand,,} == "asustor" ]] && [[ ${SysLog,,} == "yes" ]]; then
        # Add entry to Asustor system log
        syslog --log 0 --level 1 --user "$( whoami )" --event "Plex backup failed. Backup directory not found."
    fi
    # Abort script because backup directory not found
    exit 255
fi


#--------------------------------------------------------------------------
# Stop Plex Media Server

echo "Stopping Plex..." |& tee -a "${Log_File}"

Result=$(/usr/local/AppCentral/plexmediaserver/CONTROL/start-stop.sh stop)
# Give sockets a moment to close
sleep 5

if [[ -n $Result ]]; then
    if [[ $Result == *"stopped process in pidfile"* ]]; then
        echo "Plex Media Server has stopped." |& tee -a "$Log_File"
    elif [[ $Result == *"none killed"* ]]; then
        echo "Plex Media Server wasn't running." |& tee -a "$Log_File"
    else
        echo "$Result" |& tee -a "$Log_File"
    fi
fi


# Nicely terminate any residual Plex processes (plug-ins, tuner service and EAE etc)
###pgrep [Pp]lex | xargs kill -15 &>/dev/null
# Give sockets a moment to close
###sleep 5

# Kill any residual processes which DSM did not clean up (plug-ins and EAE)
Pids="$(ps -ef | grep -i 'plex plug-in' | grep -v grep | awk '{print $2}')"
[ "$Pids" != "" ] && kill -9 $Pids

Pids="$(ps -ef | grep -i 'plex eae service' | grep -v grep | awk '{print $2}')"
[ "$Pids" != "" ] && kill -9 $Pids

Pids="$(ps -ef | grep -i 'plex tuner service' | grep -v grep | awk '{print $2}')"
[ "$Pids" != "" ] && kill -9 $Pids

# Give sockets a moment to close
sleep 2


#--------------------------------------------------------------------------
# Check if all Plex processes have stopped

echo Checking status of Plex processes... |& tee -a "${Log_File}"
Response=$(pgrep -l plex)
# Check if plexmediaserver was found in $Response
if [[ -n $Response ]]; then
    # Forcefully kill any residual Plex processes (plug-ins, tuner service and EAE etc)
    pgrep [Pp]lex | xargs kill -9 &>/dev/null
    sleep 5

    # Check if plexmediaserver still found in $Response
    Response=$(pgrep -l plex)
    if [[ -n $Response ]]; then
        echo "ERROR: Some Plex processes still running! Aborting backup."\
            |& tee -a "${Log_File}" "${Tmp_Err_Log_File}"
        echo "${Response}" |& tee -a "${Log_File}" "${Tmp_Err_Log_File}"
        # Start Plex to make sure it's not left partially running
        /usr/local/AppCentral/plexmediaserver/CONTROL/start-stop.sh start
        if [[ ${Brand,,} == "asustor" ]] && [[ ${SysLog,,} == "yes" ]]; then
            # Add entry to Asustor system log
            syslog --log 0 --level 1 --user "$( whoami )" --event "Plex backup failed. Plex didn't shut down."
        fi
        # Abort script because Plex didn't shut down fully
        exit 255
    else
        echo "All Plex processes have stopped." |& tee -a "${Log_File}"
    fi
else
    echo "All Plex processes have stopped." |& tee -a "${Log_File}"
fi


#--------------------------------------------------------------------------
# Backup Plex Media Server

echo "=================================================" |& tee -a "${Log_File}"
echo "Backing up Plex Media Server data files..." |& tee -a "${Log_File}"

Exclude_File="$( dirname -- "$0"; )/plex_backup_exclude.txt"

# Check for test or error arguments
if [[ -n $1 ]] && [[ ${1,,} == "error" ]]; then
    # Trigger an error to test error logging
    Test="Plex Media Server/Logs/ERROR/"
    echo "Running small error test backup of Logs folder" |& tee -a "${Log_File}"
elif [[ -n $1 ]] && [[ ${1,,} == "test" ]]; then
    # Test on small Logs folder only
    Test="Plex Media Server/Logs/"
    echo "Running small test backup of Logs folder" |& tee -a "${Log_File}"
fi

# Check if exclude file exists
# Must come after "Check for test or error arguments"
if [[ -f $Exclude_File ]]; then
    # Unset arguments
    while [[ $1 ]]; do shift; done
    # Set -X excludefile arguments for tar
    set -- "$@" "-X"
    set -- "$@" "${Exclude_File}"
else
    echo "INFO: No exclude file found." |& tee -a "${Log_File}"
fi

# Use short variable names so tar command is not too long
BD="${Backup_Directory}"
BN="${Backup_Name}"
PDP="${Plex_Data_Path}"
LF="${Log_File}"
TELF="${Tmp_Err_Log_File}"
PMS="Plex Media Server"

# Run tar backup command
if [[ -n $Test ]]; then
    # Running backup test or error test
    if [[ ${LogAll,,} == "yes" ]]; then
        echo "Logging all archived files" |& tee -a "${Log_File}"
        tar -cvpzf "${BD}"/"${BN}".tgz -C "${PDP}" "${Test}" > >(tee -a "${LF}") 2> >(tee -a "${LF}" "${TELF}" >&2)
    else
        # Don't log all backed up files.
        echo "Only logging errors" |& tee -a "${Log_File}"
        tar -cvpzf "${BD}"/"${BN}".tgz -C "${PDP}" "${Test}" 2> >(tee -a "${LF}" "${TELF}" >&2)
    fi
else
    # Backup to tgz with PMS version and date in file name, send all output to shell and log, plus errors to error.log
    # Using -C to change directory to "/share/Plex/Library/Application Support" to not backup absolute path
    # and avoid "tar: Removing leading /" error
    if [[ ${LogAll,,} == "yes" ]]; then
        echo "Logging all archived files" |& tee -a "${Log_File}"
        tar -cvpzf "${BD}"/"${BN}".tgz "$@" -C "${PDP}" "$PMS/" > >(tee -a "${LF}") 2> >(tee -a "${LF}" "${TELF}" >&2)
    else
        # Don't log all backed up files.
        echo "Only logging errors" |& tee -a "${Log_File}"
        tar -cvpzf "${BD}"/"${BN}".tgz "$@" -C "${PDP}" "$PMS/" 2> >(tee -a "${LF}" "${TELF}" >&2)
    fi
fi

echo "Finished backing up Plex Media Server data files." |& tee -a "${Log_File}"
echo "=================================================" |& tee -a "${Log_File}"


#--------------------------------------------------------------------------
# Start Plex Media Server

echo "Starting Plex..." |& tee -a "${Log_File}"
/usr/local/AppCentral/plexmediaserver/CONTROL/start-stop.sh start


#--------------------------------------------------------------------------
# Append the time taken to stdout and log file

# End Time and Date
Finished=$( date )

# bash timer variable to log time taken to backup Plex
end="${SECONDS}"

# Elapsed time in seconds
Runtime=$(( end - start ))

# Append start and end date/time and runtime
echo -e "\nBackup Started: " "${Started}" |& tee -a "${Log_File}"
echo "Backup Finished:" "${Finished}" |& tee -a "${Log_File}"
# Append days, hours, minutes and seconds from $Runtime
printf "Backup Duration: " |& tee -a "${Log_File}"
printf '%dd:%02dh:%02dm:%02ds\n' \
$((Runtime/86400)) $((Runtime%86400/3600)) $((Runtime%3600/60))\
    $((Runtime%60)) |& tee -a "${Log_File}"


#--------------------------------------------------------------------------
# Trigger cleanup function

exit 0

