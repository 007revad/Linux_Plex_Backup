#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2181
#--------------------------------------------------------------------------
# Companion script for Backup Asustor Plex script.
# v1.0.0  04-Feb-2023  007revad
#
#   MUST be run by a user in sudo, sudoers or wheel group, or as root
#
# To run the script:
# sudo i /volume1/scripts/restore_asustor_plex_backup.sh
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
    # shellcheck disable=SC1091
    source "$(dirname -- "$0";)"/backup_asustor_plex.config
else
    echo "backup_asustor_plex.config file missing!"
    exit 1
fi


# Check if backup directory exists
# shellcheck disable=SC2154
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


#--------------------------------------------------------------------------
# Set NAS name (used in backup and log filenames)

# shellcheck disable=SC2154
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
# Get list of backups from backup path

# BusyBox gives an error if process substitution is used by non-root user!
# filelist=()
# readarray -d '' filelist < <(find "${Backup_Directory}/" -size +100\
#    \( -iname "${Nas}*.tgz" -o -iname "${Nas}*.tar.gz" \) -print0)

# set +m only needed for interactive command line. In a script job control is off by default.
#set +m
shopt -s lastpipe
u_filelist=()
BD="${Backup_Directory}"
if [[ ${1,,} == "test" ]]; then
    echo "Listing only small test backups to restore"
    find "${BD}/" -maxdepth 1 -size -1000k \( -iname "${Nas}*.tgz" -o -iname "${Nas}*.tar.gz" \) -print0 |\
        while IFS=  read -r -d $'\0'; do u_filelist+=("$REPLY"); done; declare -p u_filelist >/dev/null
else
    find "${BD}/" -maxdepth 1 -size +999k \( -iname "${Nas}*.tgz" -o -iname "${Nas}*.tar.gz" \) -print0 |\
        while IFS=  read -r -d $'\0'; do u_filelist+=("$REPLY"); done; declare -p u_filelist >/dev/null
fi

# Sort array into new array
IFS=$'\n'
filelist=($(sort <<<"${u_filelist[*]}"))
unset IFS

# Menu to select file to restore
echo "Please select a file to restore:"
num="0"
while [[ $num -lt "${#filelist[@]}" ]]; do
    echo "$((num +1))) $(basename "${filelist[$num]}")"
    num=$((num +1))
done
echo "$((num +1))) Quit"
read -r choice

# Validate choice
if [[ ! $choice -eq "0" ]] &&  [[ $choice =~ ^[0-9]+$ ]] && [[ ! $choice -gt "${#filelist[@]}" ]];
then
    index=$((choice -1))
    echo "You selected: $(basename "${filelist[$index]}")"
    tgz_file="${filelist[$index]}"
else
    exit
fi


#--------------------------------------------------------------------------
# Set log names

Backup_Name="Restore_Plex_Backup"

# Set log filename
Log_File="${Backup_Directory}"/"${Backup_Name}".log
echo "Restores Asustor Plex Backup" |& tee "${Log_File}"

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
        echo -e "\n\e[41mWARNING\e[0m Plex restoration had errors! See error log:"
        echo -e "\nWARNING Plex restoration had errors! See error log:" >> "${Log_File}"
        echo -e "$(basename -- "${Err_Log_File}")\n" |& tee -a "${Log_File}"
    else
        # Log and notify of backup success
        echo -e "\nPlex restoration completed successfully" |& tee -a "${Log_File}"
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
# Start logging

# Log NAS brand, model, DSM version and hostname
Model="$(awk '/^Model\s/{print $3}' /etc/nas.conf)"
ADMversion="$(awk '/^Version\s/{print $3}' /etc/nas.conf)"
echo "${Brand}" "${Model}" ADM "${ADMversion}" |& tee -a "${Log_File}"
echo "Hostname: $( hostname )" |& tee -a "${Log_File}"

# Log Plex version
echo Plex version: "${Version}" |& tee -a "${Log_File}"


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
[ "$Pids" != "" ] && kill -9 "$Pids"

Pids="$(ps -ef | grep -i 'plex eae service' | grep -v grep | awk '{print $2}')"
[ "$Pids" != "" ] && kill -9 "$Pids"

Pids="$(ps -ef | grep -i 'plex tuner service' | grep -v grep | awk '{print $2}')"
[ "$Pids" != "" ] && kill -9 "$Pids"

# Give sockets a moment to close
sleep 2


#--------------------------------------------------------------------------
# Check if all Plex processes have stopped

echo Checking status of Plex processes... |& tee -a "${Log_File}"
Response=$(pgrep -l plex)
# Check if plexmediaserver was found in $Response
if [[ -n $Response ]]; then
    # Forcefully kill any residual Plex processes (plug-ins, tuner service and EAE etc)
    pgrep plex | xargs kill -9 &>/dev/null
    sleep 2

    # Check if plexmediaserver still found in $Response
    Response=$(pgrep -l plex)
    if [[ -n $Response ]]; then
        echo "ERROR: Some Plex processes still running! Aborting restore."\
            |& tee -a "${Log_File}" "${Tmp_Err_Log_File}"
        echo "${Response}" |& tee -a "${Log_File}" "${Tmp_Err_Log_File}"
        # Start Plex to make sure it's not left partially running
        /usr/local/AppCentral/plexmediaserver/CONTROL/start-stop.sh start
        # Abort script because Plex didn't shut down fully
        exit 255
    else
        echo "All Plex processes have stopped." |& tee -a "${Log_File}"
    fi
else
    echo "All Plex processes have stopped." |& tee -a "${Log_File}"
fi


#--------------------------------------------------------------------------
# Restore Plex Media Server from backup

echo "=================================================" |& tee -a "${Log_File}"
echo "Restoring Plex Media Server data files from:" |& tee -a "${Log_File}"
basename "$tgz_file" |& tee -a "${Log_File}"

# Use short variable names so tar command is not too long
BD="${Backup_Directory}"
#BN="${Backup_Name}"
PDP="${Plex_Data_Path}"
LF="${Log_File}"
TELF="${Tmp_Err_Log_File}"
#PMS="Plex Media Server"

# Restore tgz backup to PMS, send all output to shell and log, plus errors to error.log
# Using -C to change directory to "/share/Plex/Library/Application Support"
# shellcheck disable=SC2154
if [[ ${LogAll,,} == "yes" ]]; then
    echo "Logging all restored files" |& tee -a "${Log_File}"
    tar -zxvpf "$tgz_file" -C "${PDP}" > >(tee -a "${LF}") 2> >(tee -a "${LF}" "${TELF}" >&2)
else
    # Don't log all backed up files.
    echo "Only logging errors" |& tee -a "${Log_File}"
    tar -zxvpf "$tgz_file" -C "${PDP}" 2> >(tee -a "${LF}" "${TELF}" >&2)
fi

echo "Finished restoring Plex Media Server data files." |& tee -a "${Log_File}"
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
echo -e "\nRestore Started: " "${Started}" |& tee -a "${Log_File}"
echo "Restore Finished:" "${Finished}" |& tee -a "${Log_File}"
# Append days, hours, minutes and seconds from $Runtime
printf "Restore Duration: " |& tee -a "${Log_File}"
printf '%dd:%02dh:%02dm:%02ds\n' \
$((Runtime/86400)) $((Runtime%86400/3600)) $((Runtime%3600/60))\
    $((Runtime%60)) |& tee -a "${Log_File}"


#--------------------------------------------------------------------------
# Trigger cleanup function

exit 0

