#!/bin/bash

#====================================================#
#File Name: bringup_vm_nics.sh
#Author: Feng Liu
#Date: 2025/April/11
#Description: assign IP to target NICs inside a VM
#  and activate it for traffic running.
#====================================================#

function usage(){
    echo "Usage: $0 <ip2> [NIC#1 NIC#2 ...]"
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

if [ $# -lt 1 ]
then
    usage
    exit 1
else
    ip2=$1
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
fi
