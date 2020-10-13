#!/bin/bash

# SIGTERM-handler this funciton will be executed when the container receives the SIGTERM signal (when stopping)
term_handler(){
	logger "Stopping Hass.io Access Point" 0
	ifdown $INTERFACE
	ip link set $INTERFACE down
	ip addr flush dev $INTERFACE
	exit 0
}

# Logging function to set verbosity of output to addon log
logger(){
    msg=$1
    level=$2
    if [ $DEBUG -ge $level ]; then
        echo $msg
    fi
}

CONFIG_PATH=/data/options.json

SSID=$(jq --raw-output ".ssid" $CONFIG_PATH)
WPA_PASSPHRASE=$(jq --raw-output ".wpa_passphrase" $CONFIG_PATH)
CHANNEL=$(jq --raw-output ".channel" $CONFIG_PATH)
ADDRESS=$(jq --raw-output ".address" $CONFIG_PATH)
NETMASK=$(jq --raw-output ".netmask" $CONFIG_PATH)
BROADCAST=$(jq --raw-output ".broadcast" $CONFIG_PATH)
INTERFACE=$(jq --raw-output ".interface" $CONFIG_PATH)
HIDE_SSID=$(jq --raw-output ".hide_ssid" $CONFIG_PATH)
DHCP=$(jq --raw-output ".dhcp" $CONFIG_PATH)
DHCP_START_ADDR=$(jq --raw-output ".dhcp_start_addr" $CONFIG_PATH)
DHCP_END_ADDR=$(jq --raw-output ".dhcp_end_addr" $CONFIG_PATH)
ALLOW_MAC_ADDRESSES=$(jq --raw-output '.allow_mac_addresses | join(" ")' $CONFIG_PATH)
DENY_MAC_ADDRESSES=$(jq --raw-output '.deny_mac_addresses | join(" ")' $CONFIG_PATH)
DEBUG=$(jq --raw-output '.debug' $CONFIG_PATH)

# Set interface as wlan0 if not specified in config
if [ ${#INTERFACE} -eq 0 ]; then
    INTERFACE="wlan0"
fi

# Set interface as wlan0 if not specified in config
if [ ${#DEBUG} -eq 0 ]; then
    DEBUG=0
fi

echo "Starting Hass.io Access Point Addon"

# Setup interface
logger "# Setup interface:" 1
logger "Add to /etc/network/interfaces: iface $INTERFACE inet static" 1
# Create and add our interface to interfaces file
echo "iface $INTERFACE inet static"$'\n' >> /etc/network/interfaces

logger "Run command: nmcli dev set $INTERFACE managed no" 1
nmcli dev set $INTERFACE managed no

logger "Run command: ip link set $INTERFACE down" 1
ip link set $INTERFACE down

logger "Add to /etc/network/interfaces: address $ADDRESS" 1
echo "address $ADDRESS"$'\n' >> /etc/network/interfaces
logger "Add to /etc/network/interfaces: netmask $NETMASK" 1
echo "netmask $NETMASK"$'\n' >> /etc/network/interfaces
logger "Add to /etc/network/interfaces: broadcast $BROADCAST" 1
echo "broadcast $BROADCAST"$'\n' >> /etc/network/interfaces

logger "Run command: ip link set $INTERFACE up" 1
ip link set $INTERFACE up

# Setup signal handlers
trap 'term_handler' SIGTERM

# Enforces required env variables
required_vars=(SSID WPA_PASSPHRASE CHANNEL ADDRESS NETMASK BROADCAST)
for required_var in "${required_vars[@]}"; do
    if [[ -z ${!required_var} ]]; then
        error=1
        echo >&2 "Error: $required_var env variable not set."
    fi
done

# Sanitise config value for hide_ssid
if [ $HIDE_SSID -ne 1 ]; then
    HIDE_SSID=0
fi

# Sanitise config value for dhcp
if [ $DHCP -ne 1 ]; then
        DHCP=0
fi

if [[ -n $error ]]; then
    exit 1
fi

# Setup hostapd.conf
logger "# Setup hostapd:" 1
logger "Add to hostapd.conf: ssid=$SSID" 1
echo "ssid=$SSID"$'\n' >> /hostapd.conf
logger "Add to hostapd.conf: wpa_passphrase=********" 1
echo "wpa_passphrase=$WPA_PASSPHRASE"$'\n' >> /hostapd.conf
logger "Add to hostapd.conf: channel=$CHANNEL" 1
echo "channel=$CHANNEL"$'\n' >> /hostapd.conf
logger "Add to hostapd.conf: ignore_broadcast_ssid=$HIDE_SSID" 1
echo "ignore_broadcast_ssid=$HIDE_SSID"$'\n' >> /hostapd.conf

### MAC address filtering
## Allow is more restrictive, so we prioritise that and set
## macaddr_acl to 1, and add allowed MAC addresses to hostapd.allow
if [ ${#ALLOW_MAC_ADDRESSES} -ge 1 ]; then
    logger "Add to hostapd.conf: macaddr_acl=1" 1
    echo "macaddr_acl=1"$'\n' >> /hostapd.conf
    ALLOWED=($ALLOW_MAC_ADDRESSES)
    logger "# Setup hostapd.allow:" 1
    logger "Allowed MAC addresses:" 0
    for mac in "${ALLOWED[@]}"; do
        echo "$mac"$'\n' >> /hostapd.allow
        logger "$mac" 0
    done
    logger "Add to hostapd.conf: accept_mac_file=/hostapd.allow" 1
    echo "accept_mac_file=/hostapd.allow"$'\n' >> /hostapd.conf
## else set macaddr_acl to 0, and add denied MAC addresses to hostapd.deny
    else
        if [ ${#DENY_MAC_ADDRESSES} -ge 1 ]; then
            logger "Add to hostapd.conf: macaddr_acl=0" 1
            echo "macaddr_acl=0"$'\n' >> /hostapd.conf
            DENIED=($DENY_MAC_ADDRESSES)
            logger "Denied MAC addresses:" 0
            for mac in "${DENIED[@]}"; do
                echo "$mac"$'\n' >> /hostapd.deny
                logger "$mac" 0
            done
            logger "Add to hostapd.conf: accept_mac_file=/hostapd.deny" 1
            echo "deny_mac_file=/hostapd.deny"$'\n' >> /hostapd.conf
## else set macaddr_acl to 0, with blank allow and deny files
            else
                logger "Add to hostapd.conf: macaddr_acl=0" 1
                echo "macaddr_acl=0"$'\n' >> /hostapd.conf
        fi

fi

# Set address for the selected interface. Not sure why this is now not being set via /etc/network/interfaces, but maybe interfaces file is no longer required...
ifconfig $INTERFACE $ADDRESS netmask $NETMASK broadcast $BROADCAST

# Add interface to hostapd.conf
logger "Add to hostapd.conf: interface=$INTERFACE" 1
echo "interface=$INTERFACE"$'\n' >> /hostapd.conf

# Setup dnsmasq.conf if DHCP is enabled in config
if [ $DHCP -eq 1 ]; then
    logger "# DHCP enabled. Setup dnsmasq:" 1
    logger "Add to dnsmasq.conf: dhcp-range=$DHCP_START_ADDR,$DHCP_END_ADDR,12h" 1
        echo "dhcp-range=$DHCP_START_ADDR,$DHCP_END_ADDR,12h"$'\n' >> /dnsmasq.conf
        logger "Add to dnsmasq.conf: interface=$INTERFACE" 1
        echo "interface=$INTERFACE"$'\n' >> /dnsmasq.conf
	else
	logger "# DHCP not enabled. Skipping dnsmasq" 1
fi

# Start dnsmasq if DHCP is enabled in config
if [ $DHCP -eq 1 ]; then
    logger "## Starting dnsmasq daemon" 1
	killall -q dnsmasq; dnsmasq -C /dnsmasq.conf
fi

logger "## Starting hostapd daemon" 1
if [ $DEBUG -gt 1 ]; then
    killall -q hostapd; hostapd -d /hostapd.conf & wait ${!}
else
    killall -q hostapd; hostapd /hostapd.conf & wait ${!}
fi