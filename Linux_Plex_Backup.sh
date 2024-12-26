#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2181
#--------------------------------------------------------------------------
# Backup Linux Plex Database to tgz file in Backup folder.
# v1.2.7  26-Dec-2024  007revad
#
#   MUST be run by a user in sudo, sudoers or wheel group, or as root
#
# To run the script:
# sudo -i /share/scripts/backup_linux_plex_to_tar.sh
#   Change /share/scripts/ to the path where this script is located
#
# To do a test run on just Plex's profiles folder run:
# sudo -i /share/scripts/backup_linux_plex_to_tar.sh test
#   Change /share/scripts/ to the path where this script is located
#
# Github: https://github.com/007revad/Linux_Plex_Backup
# Script verified at https://www.shellcheck.net/
#
# Scheduling the script:
# https://www.freecodecamp.org/news/cron-jobs-in-linux/
# https://crontab.guru/
#
# https://arnaudr.io/2020/08/24/send-emails-from-your-terminal-with-msmtp/
#--------------------------------------------------------------------------

scriptver="v1.2.7"
script=Linux_Plex_Backup


# Read variables from backup_linux_plex.config
Backup_Directory=""
Name=""
LogAll=""
KeepQty=""
to_email_address=""
from_email_address=""
if [[ -f $(dirname -- "$0";)/backup_linux_plex.config ]];then
    # shellcheck disable=SC1090,SC1091
    while read -r var; do
        if [[ $var =~ ^[a-zA-Z0-9_]+=.* ]]; then export "$var"; fi
    done < "$(dirname -- "$0";)"/backup_linux_plex.config
else
    echo "backup_linux_plex.config file missing!"
    exit 1
fi


# Check if backup directory exists
if [[ ! -d $Backup_Directory ]]; then
    echo "Backup directory not found:"
    echo "$Backup_Directory"
    echo "Check your setting in backup_linux_plex.config"
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
    distro)
        # Get Linux Distro
        Nas="$(uname -a | awk '{print $2}')"
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

# Create temp directory for temp error log
Tmp_Dir=$(mktemp -d -t plex_to_tar-XXXXXX)

# Create temp error log
Tmp_Err_Log_File=$(mktemp "${Tmp_Dir}"/errorlog-XXXXXX)


#--------------------------------------------------------------------------
# Create trap and clean up function

# Tmp logs clean up function
# shellcheck disable=SC2329
cleanup(){ 
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
        echo -e "$(basename -- "${Err_Log_File}")\n" |& tee -a "${Log_File}"
    else
        # Log and notify of backup success
        echo -e "\nPlex backup completed successfully" |& tee -a "${Log_File}"
    fi

    # Send log via email if both logging and emails are enabled
    if [[ $to_email_address && $from_email_address ]]; then
        email_contents="email_contents.txt"
        send_email "$to_email_address" "$from_email_address" "$Backup_Directory"\
            "$email_contents" "$Nas - $script log"
    fi

    exit "${arg1}"
}

trap cleanup EXIT


# Send email function
send_email(){ 
    # $1 is $to_email_address
    # $2 is $from_email_address
    # $3 is $Backup_Directory
    # $4 is $email_contents"
    # $5 is $subject
    # $6 is $mail_body

    if [[ ! -f "$Log_File" ]]; then
        echo -e "\nWARNING Cannot send email as directory $Log_File does not exist"\
            |& tee -a "${Err_Log_File}"
    elif [[ "${3}" == "" || "${4}" == "" ]]; then
        echo -e "\nWARNING Send email failed. Incorrect data was passed to \"send_email\" function"\
            |& tee -a "${Err_Log_File}"
    else
        if [[ -d "${3}" ]]; then  # Make sure directory exists
            if [[ -w "${3}" ]]; then  # Make sure directory is writable 
                if [[ -r "${3}" ]]; then  # Make sure directory is readable 
                    echo "To: ${1} " > "${3}/${4}"
                    echo "From: ${2} " >> "${3}/${4}"
                    echo "Subject: ${5}" >> "${3}/${4}"
                    echo "" >> "${3}/${4}"
                    cat "$Log_File" >> "${3}/${4}"

                    #if [[ "${1}" == "" || "${2}" == "" || "${5}" == "" || "${6}" == "" ]]; then
                    if [[ "${1}" == "" || "${2}" == "" || "${5}" == "" ]]; then
                        echo -e "\nWARNING One or more email address parameters [to, from, subject,"\
                            "mail_body] was not supplied, Cannot send an email" |& tee -a "${Log_File}"
                    else
                        if ! command -v msmtp &> /dev/null  # Verify the msmtp command is available 
                        then
                            echo -e "\nWARNING Cannot Send Email as command \"msmtp\" was not found"\
                                |& tee -a "${Log_File}"
                        else
                            local email_response=$(msmtp "${1}" < "${3}/${4}"  2>&1)
                            if [[ "$email_response" == "" ]]; then
                                echo -e "\nEmail Sent Successfully" |& tee -a "${Log_File}"
                            else
                                echo -e "\nWARNING An error occurred while sending email."\
                                    "The error was: $email_response\n\n" |& tee -a "${Log_File}"
                            fi    
                        fi
                    fi
                else
                    echo -e "Cannot send email as directory \"${3}\" does not have READ permissions"\
                        |& tee -a "${Log_File}"
                fi
            else
                echo -e "Cannot send email as directory \"${3}\" does not have WRITE permissions"\
                    |& tee -a "${Log_File}"
            fi
        else
            echo -e "Cannot send email as directory \"${3}\" does not exist" |& tee -a "${Log_File}"
        fi
    fi
}


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
# "Plex Media Server" folder location

# ADM   /volume1/Plex/Library/Plex Media Server
# DSM6  /volume1/Plex/Library/Application Support/Plex Media Server
# DSM7  /volume1/PlexMediaServer/AppData/Plex Media Server
# Linux /var/lib/plexmediaserver/Library/Application Support/Plex Media Server

# Set the Plex Media Server data location
Plex_Data_Path="/var/lib/plexmediaserver/Library/Application Support"


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

Version="$(/usr/lib/plexmediaserver/Plex\ Media\ Server --version)"
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

echo -e "$script $scriptver\n" |& tee -a "${Log_File}"

# Log Linux distro, version and hostname
Distro="$(uname -a | awk '{print $2}')"
DistroVersion="$(uname -a | awk '{print $3}' | cut -d"-" -f1)"
echo "${Distro}" "${DistroVersion}" |& tee -a "${Log_File}"
echo "Hostname: $( hostname )" |& tee -a "${Log_File}"

# Log Plex version
echo Plex version: "${Version}" |& tee -a "${Log_File}"


#--------------------------------------------------------------------------
# Check if backup directory exists

if [[ ! -d $Backup_Directory ]]; then
    echo "ERROR: Backup directory not found! Aborting backup." |& tee -a "${Log_File}" "${Tmp_Err_Log_File}"
    # Abort script because backup directory not found
    exit 255
fi


#--------------------------------------------------------------------------
# Stop Plex Media Server

echo "Stopping Plex..." |& tee -a "${Log_File}"

Result=$(systemctl stop plexmediaserver)
code="$?"
# Give sockets a moment to close
sleep 5

if [[ $code == "0" ]]; then
    echo "Plex Media Server has stopped." |& tee -a "$Log_File"
else
    echo "$Result" |& tee -a "$Log_File"
    exit $code
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
    pgrep [Pp]lex | xargs kill -9 &>/dev/null
    sleep 5

    # Check if plexmediaserver still found in $Response
    Response=$(pgrep -l plex)
    if [[ -n $Response ]]; then
        echo "ERROR: Some Plex processes still running! Aborting backup."\
            |& tee -a "${Log_File}" "${Tmp_Err_Log_File}"
        echo "${Response}" |& tee -a "${Log_File}" "${Tmp_Err_Log_File}"
        # Start Plex to make sure it's not left partially running
        /usr/lib/plexmediaserver/Resources/start.sh
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
#/usr/lib/plexmediaserver/Resources/start.sh
systemctl start plexmediaserver


#--------------------------------------------------------------------------
# Delete old backups

if [[ $KeepQty -gt "0" ]]; then
    readarray -t array < <(ls "$Backup_Directory" |\
        grep -E "${Nas}"'_[0-9]{8,}(-[0-9]{4,})?_Plex_.*\.tgz' | head -n -"$KeepQty")

    if [[ "${#array[@]}" -gt "0" ]]; then
        echo -e "\nDeleting old backups" |& tee -a "${Log_File}"
        for file in "${array[@]}"; do
            if [[ -f "$Backup_Directory/$file" ]]; then
                echo "Deleting $file" |& tee -a "${Log_File}"
                rm "$Backup_Directory/$file"
            fi
            if [[ -f "$Backup_Directory/${file%.tgz}.log" ]]; then
                echo "Deleting ${file%.tgz}.log" |& tee -a "${Log_File}"
                rm "$Backup_Directory/${file%.tgz}.log"
            fi
            if [[ -f "$Backup_Directory/${file%.tgz}_ERROR.log" ]]; then
                echo "Deleting ${file%.tgz}_ERROR.log" |& tee -a "${Log_File}"
                rm "$Backup_Directory/${file%.tgz}_ERROR.log"
            fi
        done
    fi
fi


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
# Send log via email if both logging and emails are enabled

# Send Email Notification Function
send_email(){ 
    # $1 is $to_email_address
    # $2 is $from_email_address
    # $3 is $log_file_location
    # $4 is $log_file_name
    # $5 is $subject
    # $6 is $mail_body

    if [[ "${3}" == "" || "${4}" == "" ]]; then
        echo "Incorrect data was passed to the \"send_email\" function, cannot send email"
    else
        if [[ -d "${3}" ]]; then  # Make sure directory exists
            if [[ -w "${3}" ]]; then  # Make sure directory is writable 
                if [[ -r "${3}" ]]; then  # Make sure directory is readable 
                    #local now=$(date +"%T")
                    echo "To: ${1} " > "${3}/${4}"
                    echo "From: ${2} " >> "${3}/${4}"
                    echo "Subject: ${5}" >> "${3}/${4}"
                    #echo "" >> "${3}/${4}"
                    #echo -e "\n$now - ${6}\n" >> "${3}/${4}"
                                                    
                    if [[ "${1}" == "" || "${2}" == "" || "${5}" == "" || "${6}" == "" ]]; then
                        echo -e "\n\nOne or more email address parameters [to, from, subject, mail_body] was not supplied, Cannot send an email"
                    else
                        if ! command -v msmtp &> /dev/null  # Verify the msmtp command is available 
                        then
                            echo "Cannot Send Email as command \"msmtp\" was not found"
                        else
                            local email_response=$(msmtp "${1}" < "${3}/${4}"  2>&1)
                            if [[ "$email_response" == "" ]]; then
                                echo -e "\nEmail Sent Successfully" |& tee -a "${3}/${4}"
                            else
                                echo -e "\n\nWARNING -- An error occurred while sending email. The error was: $email_response\n\n" |& tee "${3}/${4}"
                            fi    
                        fi
                    fi
                else
                    echo "Cannot send email as directory \"${3}\" does not have READ permissions"
                fi
            else
                echo "Cannot send email as directory \"${3}\" does not have WRITE permissions"
            fi
        else
            echo "Cannot send email as directory \"${3}\" does not exist"
        fi
    fi
}


if ! command -v msmtp &> /dev/null; then  # Verify the msmtp command is available 
    echo -e "\nCannot Send Email as command \"msmtp\" was not found!" |& tee -a "${Log_File}"
else
    email_response=$(msmtp "${to_email_address}" < "${Log_File}" 2>&1)
    if [[ "$email_response" == "" ]]; then
        echo -e "\nEmail sent successfully" |& tee -a "${Log_File}"
    else
        echo -e "\nWARNING An error occurred while sending email. The error was: $email_response\n" |& tee -a "${Log_File}"
    fi    
fi


#--------------------------------------------------------------------------
# Trigger cleanup function

exit 0

