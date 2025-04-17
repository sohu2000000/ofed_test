#!/bin/bash

#====================================================#
#File Name: sf_conf.sh
#Author: Feng Liu
#Date: 2025/April/11
#Description: Configure and manage SF (Smart Function) interfaces:
#  - Detect and list SF interfaces
#  - Bring up/down SF interfaces with IP configuration
#  - Test connectivity between SF interfaces
#  - Support source and destination roles for testing
#====================================================#

# Global array to store SF interface structs
sf_intfs=()

# Function to create a new sf_intf struct
function create_sf_intf() {
    local sf_name="$1"
    local sf_state="$2"
    local sf_addr="$3"
    local sf_mask="$4"
    local sf_mac="$5"
    local sf_num="$6"
    local host_type="$7"
    local peer_ip="$8"
    local peer_mac="$9"
    # Create a new struct with all fields
    # Use a different delimiter (|) to avoid issues with MAC address colons
    echo "$sf_name|$sf_state|$sf_addr|$sf_mask|$sf_mac|$sf_num|$host_type|$peer_ip|$peer_mac"
}

function sf_intf_show() {
    echo "=== SF Interfaces Information ==="
    local total_count=${#sf_intfs[@]}
    echo "Total SF interfaces found: $total_count"
    echo "----------------------------"
    local idx=0
    for sf in "${sf_intfs[@]}"; do
        # Split the struct into all fields using | as delimiter
        IFS='|' read -r name state addr mask mac sf_num host_type peer_ip peer_mac <<< "$sf"
        echo "SF Interface [$idx]:"
        echo "  Name: $name"
        echo "  State: $state"
        echo "  SF_NUM: $sf_num"
        echo "  HOST_TYPE: $host_type"
        echo "  MAC: $mac"
        if [ -n "$peer_mac" ]; then
            echo "  PEER_MAC: $peer_mac"
        fi
        if [ -n "$addr" ] && [ -n "$mask" ]; then
            echo "  IP: $addr/$mask"
            if [ -n "$peer_ip" ]; then
                echo "  PEER_IP: $peer_ip/$mask"
            fi
        else
            echo "  IP: /"
        fi
        ((idx++))
    done
    echo "==========================="
    echo "Total SF interfaces: $total_count"
}

# Function to display usage
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo "Options:"
    echo "  -u [src|dst]    Bring up SF interfaces (src: ip4=1, dst: ip4=2)"
    echo "  -d              Bring down SF interfaces"
    echo "  -s              Show SF interfaces information"
    echo "  -t, --test [src|dst]  Test SF interfaces connectivity"
    echo "  -h              Show this help message"
    exit 1
}

function wait_for_interface_up() {
    local intf_name=$1
    local max_retries=5
    local retry=0
    local wait_time=1

    while [ $retry -lt $max_retries ]; do
        local state=$(get_interface_state "$intf_name")
        if [ "$state" = "UP" ]; then
            return 0
        fi
        sleep $wait_time
        ((retry++))
    done
    return 1
}

function nic_up(){
    local dut_nic=$1
    local new_ip=$(printf '%d.%d.%d.%d/%d' $2 $3 $4 $5 $6)
    ip addr flush dev $dut_nic
    ip addr add $new_ip dev $dut_nic
    ip link set dev $dut_nic up

    # Wait for interface to come up
    if ! wait_for_interface_up "$dut_nic"; then
        echo "Warning: Interface $dut_nic may not be fully up"
    fi
}

function nic_down(){
    local dut_nic=$1
    ip addr flush dev $dut_nic
    ip link set dev $dut_nic down
}

function sf_intf_get() {
    # Clear the array first
    sf_intfs=()

    # Get all interfaces
    for intf in $(ip link show | grep -E "^[0-9]+:" | awk -F': ' '{print $2}'); do
        # Skip loopback interface
        if [ "$intf" = "lo" ]; then
            continue
        fi

        # Get driver and bus-info using ethtool
        driver=$(ethtool -i $intf 2>/dev/null | grep "driver:" | awk '{print $2}')
        bus_info=$(ethtool -i $intf 2>/dev/null | grep "bus-info:" | awk '{print $2}')

        # Check if it's an mlx5_core SF interface
        if [ "$driver" = "mlx5_core" ] && [[ "$bus_info" == mlx5_core.sf.* ]]; then
            # Get interface state
            intf_state=$(ip link show $intf | grep -o "state [A-Z]*" | awk '{print $2}')

            # Get IP address and mask if they exist
            intf_addr=""
            intf_mask=""
            ip_info=$(ip addr show $intf | grep "inet " | awk '{print $2}')
            if [ ! -z "$ip_info" ]; then
                intf_addr=$(echo $ip_info | cut -d'/' -f1)
                intf_mask=$(echo $ip_info | cut -d'/' -f2)
            fi

            # Get MAC address
            if [ -f "/sys/class/net/$intf/address" ]; then
                intf_mac=$(cat "/sys/class/net/$intf/address" 2>/dev/null)
                if [ -z "$intf_mac" ]; then
                    intf_mac="N/A"
                fi
            else
                intf_mac="N/A"
            fi

            # Calculate sf_num and host_type from MAC address
            intf_sf_num="N/A"
            intf_host_type="N/A"
            intf_peer_ip=""
            intf_peer_mac=""
            if [ "$intf_mac" != "N/A" ]; then
                # Split MAC address into parts
                IFS=':' read -r mac1 mac2 mac3 mac4 mac5 mac6 <<< "$intf_mac"

                # Convert hex to decimal and calculate sf_num
                mac4_dec=$((16#$mac4))
                mac5_dec=$((16#$mac5))
                intf_sf_num=$((mac4_dec * 256 + mac5_dec))

                # Calculate host_type based on mac6
                mac6_dec=$((16#$mac6))
                if [ $mac6_dec -eq 1 ]; then
                    intf_host_type="src"
                    peer_ip4=2
                elif [ $mac6_dec -eq 2 ]; then
                    intf_host_type="dst"
                    peer_ip4=1
                else
                    intf_host_type="unknown"
                fi

                # Calculate peer_ip and peer_mac if we have a valid host_type
                if [ "$intf_host_type" != "unknown" ]; then
                    intf_peer_ip=$(printf '%d.%d.%d.%d' 11 $mac4_dec $mac5_dec $peer_ip4)
                    intf_peer_mac=$(printf '%s:%s:%s:%s:%s:%02x' $mac1 $mac2 $mac3 $mac4 $mac5 $peer_ip4)
                fi
            fi

            # Create a new sf_intf struct and add it to the array
            sf_intfs+=("$(create_sf_intf "$intf" "$intf_state" "$intf_addr" "$intf_mask" "$intf_mac" "$intf_sf_num" "$intf_host_type" "$intf_peer_ip" "$intf_peer_mac")")
        fi
    done
}

function get_interface_state() {
    local intf_name=$1
    ip link show $intf_name | grep -o "state [A-Z]*" | awk '{print $2}'
}

function sf_intf_bringup() {
    # Check if we have any SF interfaces
    if [ ${#sf_intfs[@]} -eq 0 ]; then
        echo "No SF interfaces found. Please run with -s option first."
        exit 1
    fi

    # Fixed values
    local ip1=11
    local netmask=24

    # Bring up all SF interfaces
    local idx=0
    for sf in "${sf_intfs[@]}"; do
        # Split the struct to get interface name and IP info
        IFS='|' read -r name state addr mask mac sf_num host_type peer_ip peer_mac <<< "$sf"

        # Split MAC address into parts
        IFS=':' read -r mac1 mac2 mac3 mac4 mac5 mac6 <<< "$mac"

        # Convert hex to decimal
        ip2=$((16#$mac4))
        ip3=$((16#$mac5))
        ip4=$((16#$mac6))

        # Create IP address string
        local new_addr=$(printf '%d.%d.%d.%d' $ip1 $ip2 $ip3 $ip4)

        echo "Bringing up SF interface $name"
        echo "  MAC: $mac"
        echo "  IP: $new_addr/$netmask"
        echo "  PEER_IP: $peer_ip/$netmask"
        echo "  PEER_MAC: $peer_mac"
        nic_up "$name" "$ip1" "$ip2" "$ip3" "$ip4" "$netmask"

        # Add static ARP entry for peer
        if [ -n "$peer_ip" ] && [ -n "$peer_mac" ]; then
            echo "Adding static ARP entry for peer $peer_ip -> $peer_mac on $name"
            arp -s "$peer_ip" "$peer_mac" -i "$name"
        fi

        # Get the latest interface state
        local new_state=$(get_interface_state "$name")

        # Update the sf_intf struct with new state
        sf_intfs[$idx]="$(create_sf_intf "$name" "$new_state" "$new_addr" "$netmask" "$mac" "$sf_num" "$host_type" "$peer_ip" "$peer_mac")"
        ((idx++))
    done
}

function sf_intf_bringdown() {
    # Check if we have any SF interfaces
    if [ ${#sf_intfs[@]} -eq 0 ]; then
        echo "No SF interfaces found. Please run with -s option first."
        exit 1
    fi

    # Bring down all SF interfaces
    local idx=0
    for sf in "${sf_intfs[@]}"; do
        # Split the struct to get interface name
        IFS='|' read -r name state addr mask mac <<< "$sf"

        echo "Bringing down SF interface $name"
        nic_down "$name"

        # Get the latest interface state
        local new_state=$(get_interface_state "$name")

        # Update the sf_intf struct with empty IP and mask, and new state
        sf_intfs[$idx]="$(create_sf_intf "$name" "$new_state" "" "" "" "" "" "")"
        ((idx++))
    done

    # Flush all ARP entries
    echo "Flushing all ARP entries..."
    ip neigh flush all
}

function sf_intf_conn_check() {
    local role=$1
    if [ -z "$role" ]; then
        echo "Error: Role parameter is required (src or dst)"
        return 1
    fi
    if [[ "$role" != "src" && "$role" != "dst" ]]; then
        echo "Error: Invalid role '$role', should be 'src' or 'dst'"
        return 1
    fi

    echo "=== Checking SF Interfaces Connectivity ==="
    local total_count=${#sf_intfs[@]}
    local success_count=0
    local failed_intfs=()
    echo "Total SF interfaces to check: $total_count"
    echo "----------------------------"

    local idx=0
    for sf in "${sf_intfs[@]}"; do
        # Split the struct to get interface info
        IFS='|' read -r name state addr mask mac peer_ip peer_mac <<< "$sf"

        # Skip if interface has no IP address
        if [ -z "$addr" ] || [ -z "$mask" ]; then
            echo "SF Interface [$idx] $name: No IP address configured"
            failed_intfs+=("$name (No IP)")
            ((idx++))
            continue
        fi

        # Get current IP components
        IFS='.' read -r ip1 ip2 ip3 ip4 <<< "$addr"

        # Calculate peer IP based on role
        if [ "$role" = "src" ]; then
            peer_ip4="2"
        else
            peer_ip4="1"
        fi

        # Construct peer IP address
        peer_addr="$ip1.$ip2.$ip3.$peer_ip4"

        echo "SF Interface [$idx] $name:"
        echo "  Local IP: $addr/$mask"
        echo "  Peer IP: $peer_addr"
        echo "  Pinging peer..."

        # Try ping with retries
        local max_retries=10
        local retry=0
        local ping_success=0

        while [ $retry -lt $max_retries ]; do
            if [ $retry -gt 0 ]; then
                echo "  Retry attempt $retry/$max_retries..."
            fi

            if ping -c 3 -W 100 $peer_addr > /dev/null 2>&1; then
                echo "  Status: Connected ✓"
                ping_success=1
                ((success_count++))
                break
            else
                echo "  Status: Not Connected ✗ (Attempt $((retry + 1))/$max_retries)"
                sleep 1  # Wait 1 second before retrying
            fi
            ((retry++))
        done

        if [ $ping_success -eq 0 ]; then
            failed_intfs+=("$name")
        fi

        ((idx++))
    done
    echo "========================================"
    echo "Connectivity Test Summary:"
    echo "  Total interfaces: $total_count"
    echo "  Successfully connected: $success_count"
    if [ ${#failed_intfs[@]} -gt 0 ]; then
        echo "  Failed interfaces: ${failed_intfs[*]}"
        return 1
    fi
}

# Parse command line arguments
TEMP=$(getopt -o 'u:dst:h' --long 'test:,help' -n "$0" -- "$@") || {
    # getopt will output error message
    usage
    exit 1
}
eval set -- "$TEMP"
unset TEMP

while true; do
    case "$1" in
        '-u')
            if [ -z "$2" ]; then
                echo "Error: -u option requires 'src' or 'dst' parameter"
                usage
            fi
            if [[ "$2" != "src" && "$2" != "dst" ]]; then
                echo "Error: -u option requires 'src' or 'dst' parameter"
                usage
            fi
            role="$2"
            shift 2
            sf_intf_get
            sf_intf_bringup
            sf_intf_show
            exit 0
            ;;
        '-d')
            shift
            sf_intf_get
            sf_intf_bringdown
            sf_intf_show
            exit 0
            ;;
        '-s')
            shift
            sf_intf_get
            sf_intf_show
            exit 0
            ;;
        '-t'|'--test')
            if [ -z "$2" ]; then
                echo "Error: -t/--test option requires 'src' or 'dst' parameter"
                usage
            fi
            if [[ "$2" != "src" && "$2" != "dst" ]]; then
                echo "Error: -t/--test option requires 'src' or 'dst' parameter"
                usage
            fi
            sf_intf_get
            sf_intf_conn_check "$2"
            shift 2
            exit 0
            ;;
        '-h'|'--help')
            usage
            ;;
        '--')
            shift
            break
            ;;
        *)
            echo 'Internal error!' >&2
            exit 1
            ;;
    esac
done

# If no arguments provided or remaining arguments exist, show usage
if [ $# -ne 0 ]; then
    echo "Error: Unknown arguments: $*"
    usage
fi

