#!/bin/sh
#
# Distributed under the terms of the GNU General Public License (GPL) version 2.0
#
# script for sending updates to cloudflare.com
# based on Ben Kulbertis cloudflare-update-record.sh found at http://gist.github.com/benkulbertis
# and on George Johnson's cf-ddns.sh found at https://github.com/gstuartj/cf-ddns.sh
# Rewritten for Gargoyle Web Interface - Michael Gray 2018
# CloudFlare API documentation at https://api.cloudflare.com/
#
# option username - your cloudflare e-mail
# option api key - cloudflare api key, you can get it from cloudflare.com/my-account/
# option domain   - "yourdomain.TLD"
# option host - "hostname"
#
# EXIT STATUSES (line up with ddns_updater)
UPDATE_FAILED=3
UPDATE_NOT_NEEDED=4
UPDATE_SUCCESSFUL=5
# API base url
URLBASE="https://api.cloudflare.com/client/v4"
# Data files
DATAFILE="/var/run/cloudflare-ddns-helper.dat"
ERRFILE="/var/run/cloudflare-ddns-helper.err"
# IPv4       0-9   1-3x "." 0-9  1-3x "." 0-9  1-3x "." 0-9  1-3x
IPV4_REGEX="[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}"
# IPv6       ( ( 0-9a-f  1-4char ":") min 1x) ( ( 0-9a-f  1-4char   )optional) ( (":" 0-9a-f 1-4char  ) min 1x)
IPV6_REGEX="\(\([0-9A-Fa-f]\{1,4\}:\)\{1,\}\)\(\([0-9A-Fa-f]\{1,4\}\)\{0,1\}\)\(\(:[0-9A-Fa-f]\{1,4\}\)\{1,\}\)"

if [ $# != 9 ] ; then
	logger -t cloudflare-ddns-helper "Incorrect number of arguments supplied. Exiting"
	echo "cloudflare-ddns-helper usage:"
	echo -e "\tusername\tyour cloudflare email"
	echo -e "\tapi_key\t\tyour cloudflare api key"
	echo -e "\tdomain\t\tyourdomain.TLD"
	echo -e "\thost\t\thostname"
	echo -e "\ttest_domain\tDomain to use for checking remote IP"
	echo -e "\tlocal_ip\tIP address to be sent to cloudflare"
	echo -e "\tforce_update\t1 to force update of IP, 0 to exit if already matched"
	echo -e "\tverbose\t\t0 for low output or 1 for verbose logging"
	echo -e "\tipv6\t\t0 for IPv4 output or 1 for IPv6"
	exit 3
fi

DOMAIN=$1
USERNAME=$2
API_KEY=$3
HOST=$4
TEST_DOMAIN=$5
LOCAL_IP=$6
FORCE_UPDATE=$7
VERBOSE=$8
IPV6=$9

[ -z "$USERNAME" ] && {
	logger -t cloudflare-ddns-helper "Invalid username"
	exit 3
}
[ -z "$API_KEY" ] && {
	logger -t cloudflare-ddns-helper "Invalid API key"
	exit 3
}
[ -z "$DOMAIN" ] && {
	logger -t cloudflare-ddns-helper "Invalid domain"
	exit 3
}
[ -z "$LOCAL_IP" ] && {
	logger -t cloudflare-ddns-helper "Invalid local IP"
	exit 3
}

[ $VERBOSE -eq  1 ] && logger -t cloudflare-ddns-helper "Username: $USERNAME, API KEY: $API_KEY"
[ $VERBOSE -eq  1 ] && logger -t cloudflare-ddns-helper "Domain: $DOMAIN, Host: $HOST, Test Domain: $TEST_DOMAIN, Local IP: $LOCAL_IP"

# Change this to APIv4 compliant format
# domain = base domain e.g. example.com
# host = FQDN e.g. example.com for "domain record" or host.sub.example.com for "host record"
# if handling a domain record then make host = domain
[ -z "$HOST" ] && HOST=$DOMAIN
# if handling host record then format
[ "$HOST" != "$DOMAIN" ] && HOST="${HOST}.$DOMAIN"
[ $VERBOSE -eq  1 ] && logger -t cloudflare-ddns-helper "Host: $HOST, Domain: $DOMAIN"

command_runner()
{
	[ $VERBOSE -eq  1 ] && logger -t cloudflare-ddns-helper "cmd: $RUNCMD"
	eval "$RUNCMD"
	ERR=$?
	if [ $ERR != 0 ] ; then
		logger -t cloudflare-ddns-helper "cURL error: $ERR"
		logger -t cloudflare-ddns-helper $(cat $ERRFILE)
		#echo "$(cat $ERRFILE)"
		return 1
	fi
	
	# check status
	STATUS=$(grep '"success": \?true' $DATAFILE)
	if [ -z "$STATUS" ]; then
		logger -t cloudflare-ddns-helper "Cloudflare responded with an error"
		logger -t cloudflare-ddns-helper $(cat $DATAFILE)
		#echo "$(cat $DATAFILE)"
		return 1
	fi
	
	return 0
}

# base command
CMDBASE="curl -RsS -o $DATAFILE --stderr $ERRFILE"

# force IP version
[ $IPV6 -eq 0 ] && CMDBASE="$CMDBASE -4 " || CMDBASE="$CMDBASE -6 "

# add headers
CMDBASE="$CMDBASE --header 'X-Auth-Email: $USERNAME' "
CMDBASE="$CMDBASE --header 'X-Auth-Key: $API_KEY' "
CMDBASE="$CMDBASE --header 'Content-Type: application/json' "

# fetch zone id for domain
RUNCMD="$CMDBASE --request GET '$URLBASE/zones?name=$DOMAIN'"
command_runner || exit 3

ZONEID=$(grep -o '"id": \?"[^"]*' $DATAFILE | grep -o '[^"]*$' | head -1)
if [ -z "$ZONEID" ] ; then
	logger -t cloudflare-ddns-helper "Could not detect zone ID for domain: $DOMAIN"
	exit 3
fi
[ $VERBOSE -eq  1 ] && logger -t cloudflare-ddns-helper "Zone ID for $DOMAIN: $ZONEID"

# get A or AAAA record
[ $IPV6 -eq 0 ] && TYPE="A" || TYPE="AAAA"
RUNCMD="$CMDBASE --request GET '$URLBASE/zones/$ZONEID/dns_records?name=$HOST&type=$TYPE'"
command_runner || exit 3

RECORDID=$(grep -o '"id": \?"[^"]*' $DATAFILE | grep -o '[^"]*$' | head -1)
if [ -z "$RECORDID" ] ; then
	logger -t cloudflare-ddns-helper "Could not detect record ID for host: $HOST"
	exit 3
fi
[ $VERBOSE -eq  1 ] && logger -t cloudflare-ddns-helper "Record ID for $HOST: $RECORDID"

# if we got this far, we can check the data for the current IP address
DATA=$(grep -o '"content": \?"[^"]*' $DATAFILE | grep -o '[^"]*$' | head -1)
[ $IPV6 -eq 0 ] \
	&& DATA=$(printf "%s" "$DATA" | grep -m 1 -o "$IPV4_REGEX") \
	|| DATA=$(printf "%s" "$DATA" | grep -m 1 -o "$IPV6_REGEX")
[ $VERBOSE -eq  1 ] && logger -t cloudflare-ddns-helper "Remote IP for $HOST: $DATA"

if [ -n "$DATA" ]; then
	[ "$DATA" = "$LOCAL_IP" ] && {
		[ $FORCE_UPDATE = 0 ] && {
			[ $VERBOSE -eq  1 ] && logger -t cloudflare-ddns-helper "Remote IP = Local IP, no update needed"
			exit 4
		}
		[ $VERBOSE -eq  1 ] && logger -t cloudflare-ddns-helper "Remote IP = Local IP, force update requested"
	}
fi

# if we got this far, we need to update IP with cloudflare
cat > $DATAFILE << EOF
{"id":"$ZONEID","type":"$TYPE","name":"$HOST","content":"$LOCAL_IP"}
EOF

RUNCMD="$CMDBASE --request PUT --data @$DATAFILE '$URLBASE/zones/$ZONEID/dns_records/$RECORDID'"
command_runner || exit 3

[ $VERBOSE -eq  1 ] && logger -t cloudflare-ddns-helper "Remote IP updated to $LOCAL_IP"
exit 5

