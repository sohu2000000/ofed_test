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
    # Create a new struct with sf_name and sf_state
    local -A sf_intf=(
        ["sf_name"]="$sf_name"
        ["sf_state"]="$sf_state"
    )
    echo "${sf_intf[@]}"
}

function sf_intf_show() {
    echo "=== SF Interfaces Information ==="
    echo "Total SF interfaces found: ${#sf_intfs[@]}"
    echo "----------------------------"
    local idx=0
    for sf in "${sf_intfs[@]}"; do
        # Split the struct into name and state
        IFS=' ' read -r name state <<< "$sf"
        echo "SF Interface [$idx]:"
        echo "  Name: $name"
        echo "  State: $state"
        ((idx++))
    done
    echo "==========================="
}

function usage(){
    echo "Usage: $0 [-s] | <ip2> [NIC#1 NIC#2 ...]"
    echo "Options:"
    echo "  -s, --show    Show SF interfaces information"
    echo ""
    echo "Or assign IPs to NICs:"
    echo "e.g.: if you run $0 100 eth1 eth2 eth3 inside VM clx-mus-15-005"
    echo "it will assign 11.100.15.5/16 to eth1"
    echo "               12.100.15.5/16 to eth2"
    echo "               13.100.15.5/16 to eth3"
    echo "the NIC names are optional, if not specified, all NICs without IPs will be used."
    echo "but the order is not guaranteed, so it's better to specify the NIC names."
}

function nic_up(){
    local dut_nic=$1
    local new_ip=$(printf '%d.%d.%d.%d/%d' $2 $3 $4 $5 $6)
    ip addr flush dev $dut_nic
    ip addr add $new_ip dev $dut_nic
    ip link set dev $dut_nic up
}

function sf_intf_get() {
    # Clear the array first
    sf_intfs=()

    # Get all SF interfaces and store them in the array
    while IFS= read -r line; do
        # Extract interface name and state from the line
        intf_name=$(echo "$line" | awk -F': ' '{print $2}')
        intf_state=$(echo "$line" | grep -o "state [A-Z]*" | awk '{print $2}')
        # Create a new sf_intf struct and add it to the array
        sf_intfs+=("$(create_sf_intf "$intf_name" "$intf_state")")
    done < <(ip a | grep "enp81s0f0s*")
}

function bring_up_main() {
    local ip2=$1
    shift

    # Get all NICs without IP addresses, excluding loopback
    nics_without_ip=$(ip -o link show | awk -F': ' '$2 != "lo" {print $2}' | while read nic; do
        if ! ip addr show dev "$nic" | grep -q "inet "; then
            echo "$nic"
        fi
    done)

    # If no NICs specified as arguments, use the ones without IP
    if [ $# -eq 0 ]; then
        # Replace the positional parameters ($1, $2, etc) with the list of NICs that don't have IP addresses
        # This allows the script to process all NICs without IPs if no specific NICs were provided as arguments
        set -- $nics_without_ip
    fi

    ip1=11
    ip3=$(expr $(hostname -s|awk -F'-' "{print \$3}"|tr -dc '0-9') + 0)
    ip4=$(expr $(hostname -s|awk -F'-' "{print \$4}"|tr -dc '0-9') + 0)

    for nic in $@
    do
        echo "bring up NIC $nic"
        nic_up $nic $ip1 $ip2 $ip3 $ip4 16
        ((ip1++))
    done
}

# Parse command line arguments
if [ "$1" = "-s" ] || [ "$1" = "--show" ]; then
    sf_intf_get
    sf_intf_show
    exit 0
fi

if [ $# -lt 1 ]; then
    usage
    exit 1
fi

bring_up_main "$@"

