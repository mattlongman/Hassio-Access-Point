#!/bin/bash

# SIGTERM-handler this funciton will be executed when the container receives the SIGTERM signal (when stopping)
term_handler(){
	echo "Stopping..."
	ifdown $INTERFACE
	ip link set $INTERFACE down
	ip addr flush dev $INTERFACE
	exit 0
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

# Set interface as wlan0 if not specified in config
if [ ${#INTERFACE} -eq 0 ]; then
    INTERFACE="wlan0"
fi

echo "iface $INTERFACE inet static"$'\n' >> /etc/network/interfaces


echo "Set nmcli managed no"
nmcli dev set $INTERFACE managed no

# Setup signal handlers
trap 'term_handler' SIGTERM

echo "Starting..."



### MAC address filtering
## Allow is more restrictive, so we prioritise that and set
## macaddr_acl to 1, and add allowed MAC addresses to hostapd.allow
if [ ${#ALLOW_MAC_ADDRESSES} -ge 1 ]; then
    echo "macaddr_acl=1"$'\n' >> /hostapd.conf
    ALLOWED=($ALLOW_MAC_ADDRESSES)
    for mac in "${ALLOWED[@]}"; do
        echo "$mac"$'\n' >> /hostapd.allow
    done
    echo "accept_mac_file=/hostapd.allow"$'\n' >> /hostapd.conf
## else set macaddr_acl to 0, and add denied MAC addresses to hostapd.deny
    else
        if [ ${#DENY_MAC_ADDRESSES} -ge 1 ]; then
            echo "macaddr_acl=0"$'\n' >> /hostapd.conf
            DENIED=($DENY_MAC_ADDRESSES)
            for mac in "${DENIED[@]}"; do
                echo "$mac"$'\n' >> /hostapd.deny
            done
            echo "deny_mac_file=/hostapd.deny"$'\n' >> /hostapd.conf
## else set macaddr_acl to 0, with blank allow and deny files
            else
                echo "macaddr_acl=0"$'\n' >> /hostapd.conf
        fi

fi



# Add interface to hostapd.conf
echo "interface=$INTERFACE"$'\n' >> /hostapd.conf

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
echo "Setup hostapd ..."
echo "ssid=$SSID"$'\n' >> /hostapd.conf
echo "wpa_passphrase=$WPA_PASSPHRASE"$'\n' >> /hostapd.conf
echo "channel=$CHANNEL"$'\n' >> /hostapd.conf
echo "ignore_broadcast_ssid=$HIDE_SSID"$'\n' >> /hostapd.conf

# Setup dnsmasq.conf if DHCP is enabled in config
echo "Setup dnsmasq ..."
if [ $DHCP -eq 1 ]; then
        echo "dhcp-range=$DHCP_START_ADDR,$DHCP_END_ADDR,12h"$'\n' >> /dnsmasq.conf
        echo "interface=$INTERFACE"$'\n' >> /dnsmasq.conf
	else
	echo "DHCP not enabled"
fi

# Setup interface
echo "Setup interface ..."

#ip link set wlan0 down
#ip addr flush dev wlan0
#ip addr add ${IP_ADDRESS}/24 dev wlan0
#ip link set wlan0 up

## extra killall thrown in - not required? ## killall hostapd

ip link set $INTERFACE down


## move this ^ ## echo "iface $INTERFACE inet static"$'\n' >> /etc/network/interfaces
echo "address $ADDRESS"$'\n' >> /etc/network/interfaces
echo "netmask $NETMASK"$'\n' >> /etc/network/interfaces
echo "broadcast $BROADCAST"$'\n' >> /etc/network/interfaces


ip link set $INTERFACE up

# Start dnsmasq if DHCP is enabled in config
if [ $DHCP -eq 1 ]; then
	killall dnsmasq; dnsmasq -C /dnsmasq.conf
fi

echo "Starting HostAP daemon ..."
killall hostapd; hostapd -d /hostapd.conf & wait ${!}
