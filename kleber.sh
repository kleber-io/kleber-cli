#!/bin/sh
# --
# Kleber (kleber.io) command line client
#
# Version:      v0.4.1
# Home:         https://github.com/kleber-io/kleber-cli
# License:      GPLv3 (see LICENSE for full license text)
#
#
# Usage:        kleber --help
# --
set -e
VERSION="0.4.1"
DEBUG=0
KLEBER_WEB_URL="https://kleber.io"
KLEBER_API_URL="${KLEBER_WEB_URL}/api"
KLEBER_MAX_SIZE=262144000
KLEBER_RCFILE=~/.kleberrc
ARGS="$*"
USERAGENT="Kleber CLI client v${VERSION}"
CLIPPER=
CLIPPER_CMD=
UPLOAD_LIFETIME=604800
SECURE_URL=0
NO_LEXER=0
API_URL=0
EXIFTOOL=0
TMPDIR=$(mktemp -dt kleber.XXXXXX)
trap "rm -rf '$TMPDIR'" EXIT TERM

err(){
    exitval=$1
    shift
    echo 1>&2 "ERROR: $*"
    exit "$exitval"
}

warn(){
    echo 1>&2 "WARNING: $*"
}

info(){
    if [ -z "$QUIET" ] || checkseyno "$QUIET";then
        echo -e "$*"
    fi
}

debug(){
    case $DEBUG in
    [Yy][Ee][Ss]|[Tt][Rr][Uu][Ee]|[Oo][Nn]|1)
        echo 1>&2 "DEBUG: $*"
        ;;
    esac
}

checkyesno(){
    if [ -z "$1" ];then
        return 1
    fi
    eval _value=\$${1}
    debug "checkyesno: $1 is set to $_value."
    case $_value in
        #   "yes", "true", "on", or "1"
    [Yy][Ee][Ss]|[Tt][Rr][Uu][Ee]|[Oo][Nn]|1)
        return 0
        ;;
        #   "no", "false", "off", or "0"
    [Nn][Oo]|[Ff][Aa][Ll][Ss][Ee]|[Oo][Ff][Ff]|0)
        return 1
        ;;
    *)
        return 1
        ;;
    esac
}

check_euid(){
    if [ "$(id -u)" = 0 ]; then
      warn "You should not run this with superuser privileges!"
      read
    fi
}

check_dependencies(){
    if ! which curl >/dev/null;then
        err 1 "Kleber CLI needs curl, please install it."
    fi

    if which xclip >/dev/null;then
        CLIPPER=1
        CLIPPER_CMD="xclip -selection clipboard"
    else
        CLIPPER=0
    fi
}

cmdline(){
    arg=
    for arg
    do
        delim=""
        case "$arg" in
            --debug)          args="${args}-x ";;
            --upload)         args="${args}-u ";;
            --delete)         args="${args}-d ";;
            --list)           args="${args}-l ";;
            --remove-meta)    args="${args}-e ";;
            --name)           args="${args}-n ";;
            --lifetime)       args="${args}-t ";;
            --offset)         args="${args}-o ";;
            --limit)          args="${args}-k ";;
            --clipboard)      args="${args}-p ";;
            --secure-url)     args="${args}-s ";;
            --config)         args="${args}-c ";;
            --curl-config)    args="${args}-C ";;
            --api-url)        args="${args}-a ";;
            --help)           args="${args}-h ";;
            --quiet)          args="${args}-q ";;
            *)
                if [ ! "$(expr substr "${arg}" 0 1)" = "-" ];then
                    delim="\""
                fi
                args="${args}${delim}${arg}${delim} ";;
        esac
    done

    eval set -- "$args"

    while getopts "xhlpd:u:c:Ct:n:o:k:sgae:" OPTION
    do
        case $OPTION in
         x)
            DEBUG=1
            set -x
            ;;
         q)
            QUIET=1
            ;;
         u)
            COMMAND_UPLOAD=$OPTARG
            ;;
         d)
            COMMAND_DELETE=$OPTARG
            ;;
         l)
            COMMAND_LIST=1
            ;;
         e)
            if ! which exiftool >/dev/null;then
                err 1 "exiftool not found"
            fi

            EXIFTOOL=$(which exiftool)
            EXIFTOOL_INPUT=$OPTARG
            ;;
         n)
            UPLOAD_NAME=$OPTARG
            ;;
         t)
            UPLOAD_LIFETIME=$OPTARG
            ;;
         o)
            PAGINATION_OFFSET=$OPTARG
            ;;
         k)
            PAGINATION_LIMIT=$OPTARG
            ;;
         s)
            SECURE_URL=1
            ;;
         p)
            KLEBER_CLIPBOARD_DEFAULT=1
            ;;
         g)
            NO_LEXER=1
            ;;
         c)
            CONFIG_FILE=$OPTARG
            ;;
         a)
            API_URL=1
            ;;
         h)
            help
            exit 0
            ;;
         *)
            help
            exit 1
            ;;
        esac
    done
}

help() {
	cat <<!
Kleber command line client
usage: [cat |] $(basename "$0") [command] [options] [file|shortcut]

Commands:
    -u | --upload <file>            Upload a file
    -d | --delete <shortcut>        Delete a paste/file
    -l | --list                     Print upload history
    -e | --remove-meta <file|dir>   Remove metadata from a regular file or directory.
                                    This requires exiftool to be installed in \$PATH.

Options:
    -n | --name <name>              Name/Title for a paste
    -s | --secure-url               Create with secure URL
    -t | --lifetime <lifetime>      Set upload lifetimes (in seconds)
    -g | --no-lexer                 Don't guess a lexer for text files
    -a | --api-url                  Return web instead of API URL
    -o | --offset <offset>          Pagination offset (default: 0)
    -k | --limit <limit>            Pagination limit (default: 10)
    -c | --config                   Provide a custom config file (default: ~/.kleberrc)
    -C | --curl-config              Read curl config from stdin
    -q | --quiet                    Suppress output
    -x | --debug                    Show debug output
    -h | --help                     Show this help
!
}

load_config(){
    if [ -n "$CONFIG_FILE" ];then
        config=$CONFIG_FILE
    else
        config=$KLEBER_RCFILE
    fi

    if [ ! -r $config ] || [ ! -f $config ];then
        err 1 "Cannot read config file ${config}"
    fi


    if [ -n "$KLEBER_API_KEY" ];then
        err 1 "API key not found. Pleaase put it in the config file."
    fi

    . $config
}

read_stdin() {
    temp_file=$1
	if tty -s; then
        printf "%s\n" "^C to exit, ^D to send"
	fi
	cat > "$temp_file"
}

upload(){
    file=$1
    auth_header="X-Kleber-API-Auth: ${KLEBER_API_KEY}"
    request_url="${KLEBER_API_URL}/pastes"
    headerfile=$(mktemp "${TMPDIR}/header.XXXXXX")
    filestr="file=@${file}"

    if [ ! -r "$file" ];then
        err 1 "Cannot read file ${file}"
    elif [ "$(stat -c %s "${file}")" -eq 0 ];then
        err 1 "File size is 0"
    elif [ "$(stat -c %s "${file}")" -gt $KLEBER_MAX_SIZE ];then
        err 1 "File size exceeds maximum size"
    fi

    if [ -n "$UPLOAD_NAME" ];then
        filestr="${filestr};filename=${UPLOAD_NAME}"
    fi

    if checkyesno "$SECURE_URL";then
        SECURE_URL="secureUrl=true"
    else
        SECURE_URL="secureUrl=false"
    fi

    if checkyesno "$NO_LEXER";then
        NO_LEXER="lexer="
    else
        NO_LEXER="lexer=auto"
    fi

    curl_out=$(curl --progress-bar --tlsv1 -L --write-out '%{http_code} %{url_effective}' \
        --user-agent "$USERAGENT" \
        --header "$auth_header" \
        --header "Expect:" \
        --dump-header "$headerfile" \
        --form "$SECURE_URL" \
        --form "lifetime=${UPLOAD_LIFETIME}" \
        --form "$NO_LEXER" \
        --form "${filestr}" \
        "$request_url"
    )

    status_code="$(awk '/^HTTP\/1.1\s[0-9]{3}\s/ {print $2}' ${headerfile})"

    if [ -n "$status_code" ] && [ "$status_code" = "201" ];then
        debug "Upload successful"
        location="$(awk '/Location: (.*?)/ {print $2}' ${headerfile})"

        if checkyesno "$API_URL";then
            shortcut="$(echo $location | awk -F/ '{print $4}')"
            location="${KLEBER_API_URL}/pastes/${shortcut}"
        fi

        shortcut="$(basename "$location")"

        info "${location}"
        copy_to_clipper "$location"
    else
        handle_api_error "$status_code"
    fi
}

list(){
    offset="0"
    limit="10"
    auth_header="X-Kleber-API-Auth: ${KLEBER_API_KEY}"

    if [ -n "$PAGINATION_OFFSET" ];then
        offset="$PAGINATION_OFFSET"
    fi
    if [ -n "$PAGINATION_LIMIT" ];then
        limit="$PAGINATION_LIMIT"
    fi

    request_url="${KLEBER_API_URL}/pastes?offset=${offset}&limit=${limit}"
    curl_out=$(curl "$CURL_CONFIG_STDIN" --tlsv1 -L -s --user-agent "$USERAGENT" --header "$auth_header" "$request_url")

    echo "$curl_out"
}

delete(){
    shortcut=$1
    auth_header="X-Kleber-API-Auth: ${KLEBER_API_KEY}"
    request_url="${KLEBER_API_URL}/pastes/${shortcut}"
    status_code=$(curl "$CURL_CONFIG_STDIN" -s -X DELETE --tlsv1 --ipv4 -L \
        --write-out '%{http_code}' \
        --header "$auth_header" "$request_url" |grep -Po "[0-9]{3}$"
    )

    if [ "$status_code" -eq "204" ];then
        debug "Upload successfully deleted"
    else
        handle_api_error "$status_code"
    fi
}

copy_to_clipper(){
    location=$1

    if checkyesno "$KLEBER_CLIPBOARD_DEFAULT";then
        if checkyesno "$CLIPPER";then
            echo "$location" | eval "${CLIPPER_CMD}" || return 1
        else
            warn "xclip not found"
        fi
    fi
}

remove_meta(){
    # A very simple exiftool wrapper that removes all metadata it knows.
    input=$1
    
    if [ -f $input ];then
        $EXIFTOOL -all= $input >/dev/null 2>&1
        RET=$?
    elif [ -d $input ];then
        $EXIFTOOL -r -all= $input >/dev/null 2>&1
        RET=$?
    else
        err 1 "You need to supply a regular file or a directory."
    fi

    if [ "$RET" = 0 ];then
        info "Metadata removed"
    else
        err 1 "Removing metadata failed!"
    fi
}

handle_api_error(){
    status_code=$1

    case $status_code in
        400)
            err 1 "Invalid request data"
            ;;
        401)
            err 1 "Invalid or missing authentication token"
            ;;
        403)
            err 1 "You are not authorized to access this resource"
            ;;
        404)
            err 1 "Resource not found"
            ;;
        413)
            err 1 "Request entity too large"
            ;;
        429)
            err 1 "Rate limit reached. Please try again later"
            ;;
        500)p
            err 1 "An error occured. Please try again later"
            ;;
        503)
            err 1 "API currently not available. Please try again later"
            ;;
        *)
            err 1 "Unknown API error"
            ;;
    esac
}


### Main application logic ###
main(){
    check_euid
    check_dependencies
    cmdline $ARGS
    load_config

    if [ -n "$COMMAND_UPLOAD" ];then
        upload "$COMMAND_UPLOAD"
    elif [ -n "$COMMAND_DELETE" ];then
        delete "$COMMAND_DELETE"
    elif [ -n "$COMMAND_LIST" ];then
        list
    elif [ "$EXIFTOOL" != 0 ];then
        remove_meta "$EXIFTOOL_INPUT"
    else
        tmpfile=$(mktemp "${TMPDIR}/data.XXXXXX")
        read_stdin "$tmpfile"
        upload "$tmpfile"
    fi

    return 0
}

main
