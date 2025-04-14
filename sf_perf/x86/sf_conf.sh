#!/bin/bash

#====================================================#
#File Name: bringup_vm_nics.sh
#Author: Feng Liu
#Date: 2025/April/11
#Description: assign IP to target NICs inside a VM
#  and activate it for traffic running.
#====================================================#

# Global array to store SF interface structs
sf_intfs=()

# Function to create a new sf_intf struct
function create_sf_intf() {
    local sf_name=$1
    local sf_state=$2
    local sf_addr=$3
    local sf_mask=$4
    # Create a new struct with sf_name, sf_state, addr and mask
    local -A sf_intf=(
        ["sf_name"]="$sf_name"
        ["sf_state"]="$sf_state"
        ["sf_addr"]="$sf_addr"
        ["sf_mask"]="$sf_mask"
    )
    echo "${sf_intf[@]}"
}

function sf_intf_show() {
    echo "=== SF Interfaces Information ==="
    echo "Total SF interfaces found: ${#sf_intfs[@]}"
    echo "----------------------------"
    local idx=0
    for sf in "${sf_intfs[@]}"; do
        # Split the struct into name, state, addr and mask
        IFS=' ' read -r name state addr mask <<< "$sf"
        echo "SF Interface [$idx]:"
        echo "  Name: $name"
        echo "  State: $state"
        echo "  IP: $addr/$mask"
        ((idx++))
    done
    echo "==========================="
}

# Function to display usage
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo "Options:"
    echo "  -u [src|dst]    Bring up SF interfaces (src: ip4=1, dst: ip4=2)"
    echo "  -d              Bring down SF interfaces"
    echo "  -s              Show SF interfaces information"
    echo "  -h              Show this help message"
    exit 1
}

function nic_up(){
    local dut_nic=$1
    local new_ip=$(printf '%d.%d.%d.%d/%d' $2 $3 $4 $5 $6)
    ip addr flush dev $dut_nic
    ip addr add $new_ip dev $dut_nic
    ip link set dev $dut_nic up
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

            # Create a new sf_intf struct and add it to the array
            sf_intfs+=("$(create_sf_intf "$intf" "$intf_state" "$intf_addr" "$intf_mask")")
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
    local ip2=0
    local ip3=0
    local netmask=24

    # Assign IPs to all SF interfaces
    local idx=0
    for sf in "${sf_intfs[@]}"; do
        # Split the struct to get interface name
        IFS=' ' read -r name state _ _ <<< "$sf"

        # Calculate ip2 and ip3 based on index
        # ip2 can be 0-15 (16 values)
        # ip3 can be 0-250 (251 values)
        # Total combinations: 16 * 251 = 4016 different networks
        local new_ip2=$((ip2 + (idx / 251)))
        local new_ip3=$((ip3 + (idx % 251)))

        # Ensure ip3 doesn't exceed 250
        if [ $new_ip3 -gt 250 ]; then
            echo "Error: IP address calculation would exceed maximum ip3 value of 250"
            exit 1
        fi

        # Create IP address string
        local new_addr=$(printf '%d.%d.%d.%d' $ip1 $new_ip2 $new_ip3 $ip4)

        echo "Bringing up SF interface $name"
        echo "  IP: $new_addr/$netmask"
        nic_up "$name" "$ip1" "$new_ip2" "$new_ip3" "$ip4" "$netmask"

        # Get the latest interface state
        local new_state=$(get_interface_state "$name")

        # Update the sf_intf struct with the new IP, mask and state
        sf_intfs[$idx]="$(create_sf_intf "$name" "$new_state" "$new_addr" "$netmask")"
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
        IFS=' ' read -r name state _ _ <<< "$sf"

        echo "Bringing down SF interface $name"
        nic_down "$name"

        # Get the latest interface state
        local new_state=$(get_interface_state "$name")

        # Update the sf_intf struct with empty IP and mask, and new state
        sf_intfs[$idx]="$(create_sf_intf "$name" "$new_state" "" "")"
        ((idx++))
    done
}

# Parse command line arguments
while getopts "u:ds" opt; do
    case $opt in
        u)
            if [[ "$OPTARG" != "src" && "$OPTARG" != "dst" ]]; then
                echo "Error: -u option requires 'src' or 'dst' parameter"
                usage
            fi
            if [[ "$OPTARG" == "src" ]]; then
                ip4=1
            else
                ip4=2
            fi
            sf_intf_get
            sf_intf_bringup
            sf_intf_show
            exit 0
        ;;
        d)
            sf_intf_get
            sf_intf_bringdown
            sf_intf_show
            exit 0
        ;;
        s)
            sf_intf_get
            sf_intf_show
            exit 0
        ;;
        *)
            usage
            ;;
    esac
done

# If no arguments provided, show usage
if [ $OPTIND -eq 1 ]; then
    usage
fi

