#!/bin/bash

# SIGTERM-handler this funciton will be executed when the container receives the SIGTERM signal (when stopping)
term_handler(){
	logger "Stopping Hass.io Access Point" 0
	ifdown $INTERFACE
	ip link set $INTERFACE down
	ip addr flush dev $INTERFACE
    if [ ${#VINTERFACE} -ne 0 ]; then
        iw dev $INTERFACE del
    fi
    cleanup_iptables
	exit 0
}


function cleanup_iptables() {
    if [ ${#VINTERFACE} -ne 0 ]; then
        iptables -t nat -D POSTROUTING -o $BASE_INTERFACE -j MASQUERADE
    fi
    iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE
    iptables -t nat -D PREROUTING -i $INTERFACE -j ACCEPT
    iptables -D INPUT -i $INTERFACE -j DROP
    iptables -D INPUT -i $INTERFACE -m state --state ESTABLISHED,RELATED -j ACCEPT
    if [ ${#VINTERFACE} -ne 0 ]; then
        wifi_net=$(ip addr show $BASE_INTERFACE | grep inet | awk '{print $2}')
        if [ ${#wifi_net} -ne 0 ]; then
            iptables -D FORWARD -i $INTERFACE -o $BASE_INTERFACE -d ${wifi_net} -j DROP
        fi
    fi
    eth_net=$(ip addr show eth0 | grep 'inet ' | awk '{print $2}')
    if [ ${#eth_net} -ne 0 ]; then
        iptables -D FORWARD -i $INTERFACE -o eth0 -d ${eth_net} -j DROP
    fi
    iptables -D INPUT -p udp -i $INTERFACE --dport 67 -j ACCEPT
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
VINTERFACE=$(jq --raw-output ".virtual_interface" $CONFIG_PATH)
ISOLATION=$(jq --raw-output ".isolation" $CONFIG_PATH)
HIDE_SSID=$(jq --raw-output ".hide_ssid" $CONFIG_PATH)
DHCP=$(jq --raw-output ".dhcp" $CONFIG_PATH)
DHCP_START_ADDR=$(jq --raw-output ".dhcp_start_addr" $CONFIG_PATH)
DHCP_END_ADDR=$(jq --raw-output ".dhcp_end_addr" $CONFIG_PATH)
ALLOW_MAC_ADDRESSES=$(jq --raw-output '.allow_mac_addresses | join(" ")' $CONFIG_PATH)
DENY_MAC_ADDRESSES=$(jq --raw-output '.deny_mac_addresses | join(" ")' $CONFIG_PATH)
DEBUG=$(jq --raw-output '.debug' $CONFIG_PATH)
HOSTAPD_CONFIG_OVERRIDE=$(jq --raw-output '.hostapd_config_override | join(" ")' $CONFIG_PATH)
CLIENT_INTERNET_ACCESS=$(jq --raw-output ".client_internet_access" $CONFIG_PATH)
CLIENT_DNS_OVERRIDE=$(jq --raw-output '.client_dns_override | join(" ")' $CONFIG_PATH)
DNSMASQ_CONFIG_OVERRIDE=$(jq --raw-output '.dnsmasq_config_override | join(" ")' $CONFIG_PATH)

# Set interface as wlan0 if not specified in config
if [ ${#INTERFACE} -eq 0 ]; then
    INTERFACE="wlan0"
fi

# If we use a virtual interface, INTERFACE points to the base interface
if [ ${#VINTERFACE} -ne 0 ]; then
    BASE_INTERFACE="${INTERFACE}"
    INTERFACE="${VINTERFACE}"    
fi

# Set debug as 0 if not specified in config
if [ ${#DEBUG} -eq 0 ]; then
    DEBUG=0
fi

echo "Starting Hass.io Access Point Addon"

# Setup interface
logger "# Setup interface:" 1
logger "Add to /etc/network/interfaces: iface $INTERFACE inet static" 1
# Create and add our interface to interfaces file
echo "iface $INTERFACE inet static"$'\n' >> /etc/network/interfaces

# Create virtual interface if needed
if [ ${#VINTERFACE} -ne 0 ]; then
    # If using virtual interface, channel must be the same as the base interface
    CHANNEL=$(iw dev $BASE_INTERFACE info | grep channel | awk '{print $2}')
    # Create virtual interface
    logger "Run command: iw dev $BASE_INTERFACE interface add $INTERFACE type __ap" 1
    iw dev $BASE_INTERFACE interface add $INTERFACE type __ap
fi

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

# Sanitise config value for isolation
if [ $ISOLATION -ne 1 ]; then
        ISOLATION=0
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

# Append override options to hostapd.conf
if [ ${#HOSTAPD_CONFIG_OVERRIDE} -ge 1 ]; then
    logger "# Custom hostapd config options:" 0
    HOSTAPD_OVERRIDES=($HOSTAPD_CONFIG_OVERRIDE)
    for override in "${HOSTAPD_OVERRIDES[@]}"; do
        echo "$override"$'\n' >> /hostapd.conf
        logger "Add to hostapd.conf: $override" 0
    done
fi

# Setup dnsmasq.conf if DHCP is enabled in config
if [ $DHCP -eq 1 ]; then
    logger "# DHCP enabled. Setup dnsmasq:" 1
    logger "Add to dnsmasq.conf: dhcp-range=$DHCP_START_ADDR,$DHCP_END_ADDR,12h" 1
        echo "dhcp-range=$DHCP_START_ADDR,$DHCP_END_ADDR,12h"$'\n' >> /dnsmasq.conf
        logger "Add to dnsmasq.conf: interface=$INTERFACE" 1
        echo "interface=$INTERFACE"$'\n' >> /dnsmasq.conf

    ## DNS
    dns_array=()
        if [ ${#CLIENT_DNS_OVERRIDE} -ge 1 ]; then
            dns_string="dhcp-option=6"
            DNS_OVERRIDES=($CLIENT_DNS_OVERRIDE)
            for override in "${DNS_OVERRIDES[@]}"; do
                dns_string+=",$override"
            done
            echo "$dns_string"$'\n' >> /dnsmasq.conf
            logger "Add custom DNS: $dns_string" 0
        else
            IFS=$'\n' read -r -d '' -a dns_array < <( nmcli device show | grep IP4.DNS | awk '{print $2}' && printf '\0' )

            if [ ${#dns_array[@]} -eq 0 ]; then
                logger "Couldn't get DNS servers from host. Consider setting with 'client_dns_override' config option." 0
            else
                dns_string="dhcp-option=6"
                for dns_entry in "${dns_array[@]}"; do
                    dns_string+=",$dns_entry"
        
        
                done
                echo "$dns_string"$'\n' >> /dnsmasq.conf
                logger "Add DNS: $dns_string" 0
            fi
        fi

    # Append override options to dnsmasq.conf
    if [ ${#DNSMASQ_CONFIG_OVERRIDE} -ge 1 ]; then
        logger "# Custom dnsmasq config options:" 0
        DNSMASQ_OVERRIDES=($DNSMASQ_CONFIG_OVERRIDE)
        for override in "${DNSMASQ_OVERRIDES[@]}"; do
            echo "$override"$'\n' >> /dnsmasq.conf
            logger "Add to dnsmasq.conf: $override" 0
        done
    fi

else
	logger "# DHCP not enabled. Skipping dnsmasq" 1
    ## No DHCP == No DNS. Must be set manually on client.
fi

# Setup Client Internet Access
if [ $CLIENT_INTERNET_ACCESS -eq 1 ]; then
    ## Route traffic
    if [ ${#VINTERFACE} -ne 0 ]; then
        iptables -t nat -A POSTROUTING -o $BASE_INTERFACE -j MASQUERADE
    fi
    iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
    iptables -P FORWARD ACCEPT
    iptables -F FORWARD
fi

# Setup network isolation
if [ $ISOLATION -eq 1 ]; then
    # Do not pass packets coming from AP to docker
    iptables -t nat -I PREROUTING -i $INTERFACE -j ACCEPT
    # Accept only locally-initiated traffic
    iptables -I INPUT -i $INTERFACE -j DROP
    iptables -I INPUT -i $INTERFACE -m state --state ESTABLISHED,RELATED -j ACCEPT
    if [ ${#VINTERFACE} -ne 0 ]; then
        # Prevent access to local wifi network from AP network
        wifi_net=$(ip addr show $BASE_INTERFACE | grep inet | awk '{print $2}')
        if [ ${#wifi_net} -ne 0 ]; then
            iptables -I FORWARD -i $INTERFACE -o $BASE_INTERFACE -d ${wifi_net} -j DROP
        fi
    fi
    # Prevent access to local eth network from AP network
    eth_net=$(ip addr show eth0 | grep 'inet ' | awk '{print $2}')
    if [ ${#eth_net} -ne 0 ]; then
        iptables -I FORWARD -i $INTERFACE -o eth0 -d ${eth_net} -j DROP
    fi
    # Allow access to local DHCP server
    iptables -I INPUT -p udp -i $INTERFACE --dport 67 -j ACCEPT
fi

# Start dnsmasq if DHCP is enabled in config
if [ $DHCP -eq 1 ]; then
    logger "## Starting dnsmasq daemon" 1
	killall -q dnsmasq; dnsmasq -C /dnsmasq.conf
fi

if [ ${#VINTERFACE} -ne 0 ]; then
    # Don't know why it is needed, but hostapd fails later on without this delay
    sleep 10
fi

logger "## Starting hostapd daemon" 1
# If debug level is greater than 1, start hostapd in debug mode
if [ $DEBUG -gt 1 ]; then
    killall -q hostapd; hostapd -d /hostapd.conf & wait ${!}
else
    killall -q hostapd; hostapd /hostapd.conf & wait ${!}
fi

term_handler
