#!/bin/bash
#
# CS695 Conductor that manages containers 
# Author: <your-name>
#
echo -e "\e[1;32mCS695 Conductor that manages containers\e[0m"

set -o errexit
set -o nounset
umask 077

source "$(dirname "$0")/config.sh"

############## utility function start

die()
{
    echo "$1" >&2
    exit 1
}

check_prereq()
{
    if [ "$EUID" -ne "0" ]; then
        die "This script needs root permissions to run."
    fi

    for t in $NEEDED_TOOLS; do
        which "$t" > /dev/null || die "Missing required tools: $t"
    done

    [ -d "$CONTAINERDIR" ] || mkdir -p "$CONTAINERDIR" || die "Unable to create state dir $CONTAINERDIR"

    [ -d "$IMAGEDIR" ] || mkdir -p "$IMAGEDIR" || die "Unable to create image dir $IMAGEDIR"

    [ -d "$EXTRADIR" ] || mkdir -p "$EXTRADIR" || die "Unable to create extras dir $EXTRADIR"
}


get_next_num()
{
    local NUM=1
    if [ -f "$EXTRADIR/.HIGHEST_NUM" ]; then
        NUM=$(( 1 + $(< "$EXTRADIR/.HIGHEST_NUM" )))
    fi

    echo $NUM > "$EXTRADIR/.HIGHEST_NUM"
    printf "%x" $NUM
}

wait_for_dev()
{
    local iface="$1"
    local in_ns="${2:-}"
    local retries=5 # max retries
    local nscmd=

    [ -n "$in_ns" ] && nscmd="ip netns exec $in_ns"
    while [ "$retries" -gt "0" ]; do
        if ! $nscmd ip addr show dev $iface | grep -q tentative; then return 0; fi
        sleep 0.5
        retries=$((retries -1))
    done
}

############## utility function end


# This function will download debian container image using debootstrap 
# Downloaded images are stored within "$IMAGEDIR" directory. 
# Multiple images with different names can be created using this function
build()
{
    local NAME=${1:-}

    [ -z "$NAME" ] && die "Image name is required"

    [ -d "$IMAGEDIR/$NAME" ] && die "Image $NAME already exists"

    # Lesson: This is how debootstrap can be invoked to build filesystem for the container
    debootstrap bookworm "$IMAGEDIR/$NAME" https://deb.debian.org/debian || die "Failed to create image $NAME"
}

# This function shows all downloaded container images that are kept in .images directory
images()
{
    local IMAGES=$(ls -1 "$IMAGEDIR" 2>/dev/null || true)
    if [ -z "$IMAGES" ]; then
        echo -e "\e[1;31mNo images found\e[0m"
    else
        printf "%-20s %-10s %s\n" "Name" "Size" "Date"
        for i in $IMAGES; do
            local SIZE=$(du -sh "$IMAGEDIR/$i" | awk '{print $1}')
            local DATE=$(stat -c %y "$IMAGEDIR/$i" | awk '{print $1}')
            printf "%-20s %-10s %s\n" "$i" "$SIZE" "$DATE"
        done
    fi
}

# This function deletes a container image
remove_image()
{
    local NAME=${1:-}

    [ -z "$NAME" ] && die "Container name is required"

    [ -d "$IMAGEDIR/$NAME" ] || die "Image $NAME does not exist"
    rm -rf "$IMAGEDIR/$NAME"
    echo -e "\e[1;32m$NAME succesfully removed\e[0m"
}

# Subtask 3.a
# This function should use unshare and chroot to run a container from given image.
# You also need to mount appropriate filesystems to the rootfs within the container
# to enable tools tools that utilize those filesystems e.g. ps, top, ifconfig etc. to
# be confined within the container isolation
run()
{
    local IMAGE=${1:-}
    local NAME=${2:-}

    [ -z "$NAME" ] && die "Container name is required"
    [ -z "$IMAGE" ] && die "Image name is required"

    [ -d "$IMAGEDIR/$IMAGE" ] || die "Image $IMAGE does not exist"
    [ -d "$CONTAINERDIR/$NAME" ] && die "Container $NAME already exists"

    mkdir -p "$CONTAINERDIR/$NAME/rootfs"
    cp -a "$IMAGEDIR/$IMAGE"/* "$CONTAINERDIR/$NAME/rootfs"

    shift 2
    # this is the init command that should be run within the container
    local INIT_CMD_ARGS=${@:-/bin/bash} # if no command is given, then substitute by /bin/bash

    # Subtask 3.a.1
    # You should bind mount /dev within the container root fs
    mount --bind /dev "$CONTAINERDIR/$NAME/rootfs/dev"

    # Subtask 3.a.2
    # - Use unshare to run the container in a new [uts, pid, net, mount, ipc] namespaces
    # - You should change the root to the rootfs that has been created for the container
    # - procfs and sysfs should be mounted within the container for proper isolated execution
    #   of processes within the container
    # - When unshare process exits all of its children also exit (--kill-child option)
    # - permission of root dir within container should be set to 755 for apt to work correctly
    # - $INIT_CMD_ARGS should be the entry program for the container 
    
    mount -t sysfs sys "$CONTAINERDIR/$NAME/rootfs/sys"
    chmod 755 "$CONTAINERDIR/$NAME/rootfs"

    unshare -u -p -m -i -n --kill-child chroot "$CONTAINERDIR/$NAME/rootfs" /bin/bash -c "mount -t proc proc /proc && $INIT_CMD_ARGS"

    # umount "$CONTAINERDIR/$NAME/rootfs/proc"
    # umount "$CONTAINERDIR/$NAME/rootfs/dev"
    # umount "$CONTAINERDIR/$NAME/rootfs/sys"
}

# This will show containers that are currently running
show_containers()
{
    local CONTAINERS=$(ls -1 "$CONTAINERDIR" 2>/dev/null || true)

    if [ -z "$CONTAINERS" ]; then
        echo "No containers found"
    else
        printf "%-20s %-10s\n" "Name" "Date"
        for i in $CONTAINERS; do
            local DATE=$(stat -c %y "$CONTAINERDIR/$i" | awk '{print $1}')
            printf "%-20s %-10s\n" "$i" "$DATE"
        done
    fi
}


# This function will stop a running container
# To stop a container you need to kill the entry process within the container
# You should also unmount any mount points you created while running the container
stop()
{
    local NAME=${1:-}

    [ -z "$NAME" ] && die "Container name is required"

    [ -d "$CONTAINERDIR/$NAME" ] || die "Container $NAME does not exist"

    # Lesson: Getting the pid of the entry process within the container
    local PID=$(ps -ef | grep "$CONTAINERDIR/$NAME/rootfs" | grep -v grep | awk '{print $2}')

    # Lesson: Delete the ip link created in host for the container
    if [ -e "/sys/class/net/${NAME}-outside" ]; then
        ip link delete "${NAME}-outside"
    fi

    # Lesson: Kill the process and unmount unused points
    [ -z $PID ] || kill -9 $PID

    # This is a comprehensive list of unmounts
    # You can remove any if not required depending on how you mounted them
    umount "$CONTAINERDIR/$NAME/rootfs/proc" > /dev/null 2>&1 || :
    umount "$CONTAINERDIR/$NAME/rootfs/sys" > /dev/null 2>&1 || :
    umount "$CONTAINERDIR/$NAME/rootfs/dev" > /dev/null 2>&1 || :

    # Deletes the container file
    rm -rf "$CONTAINERDIR/$NAME"
    [ -z "$(ls -1 "$CONTAINERDIR" 2>/dev/null || true)" ] && rm -f "$EXTRADIR/.HIGHEST_NUM" &&  iptables -P FORWARD DROP && iptables -F FORWARD && iptables -t nat -F
    echo -e "\e[1;32m$NAME succesfully removed\e[0m"
}

# Subtask 3.b
# This function will execute a program within a running container
exec()
{
    # Hint: nsenter can be used to execute a process in existing namespace
    local NAME=${1:-}
    local CMD=${2:-}

    [ -z "$NAME" ] && die "Container name is required"
    
    shift # shift arguments so that remaining arguments represent the program and its arguments to execute

    # if no command is given then substitute with /bin/bash
    local EXEC_CMD_ARGS=${@:-/bin/bash}

    [ -d "$CONTAINERDIR/$NAME" ] || die "Container $NAME does not exist"

    echo -e "\e[1;32mExecuting $CMD in $NAME container!\e[0m"

    # This is the PID of the unshare process for the given container
    local UNSHARE_PID=$(ps -ef | grep "$CONTAINERDIR/$NAME/rootfs" | grep -v grep | awk '{print $2}')
    
    [ -z "$UNSHARE_PID" ] && die "Cannot find container process"

    # This is the PID of the process that unshare executed within the container
    local CONTAINER_INIT_PID=$(pgrep -P $UNSHARE_PID | head -1)

    [ -z "$CONTAINER_INIT_PID" ] && die "Cannot find container process"



    # Subtask 3.b.1
    # Write command to join the existing namespace {all namespaces: uts, pid, net, mount, ipc} 
    # of the running container and execute the given command and args. 
    # You should use $EXEC_CMD_ARGS to pass the command and arguments 
    # The executed process should be within correct namespace and root
    # directory as of the container and tools like ps, top should show only processes
    # running within the container
    nsenter --target $CONTAINER_INIT_PID  -u -p -n -m -i -w -r $EXEC_CMD_ARGS


}

# Subtask 3.c
# This function is used to setup networking capabilities of containers
# using tools like iproute2 (ip command), iptables etc.
addnetwork()
{
    local NAME=${1:-}
    [ -z "$NAME" ] && die "Container name is required"
    
    # Lesson: This folder within host is used by iproute2 to store 
    # the network namespace inode which can be used to operate on that
    # network namespace
    # 
    # If you create a network namespace using iproute2, this folder stores
    # link to inode of the created netns. inode of the network namespace is 
    # required to be present within this directory to use iproute2 to manipulate 
    # network namespace configuration.
    
    # But since we are using unshare to create netns, it will be empty. To 
    # use iproutes2, we are manually linking the netns inode unshare created
    # within this directory

    local NETNSDIR="/var/run/netns"

    if [ ! -e $NETNSDIR ]; then
        mkdir -p $NETNSDIR
    fi

    local PID=$(ps -ef | grep "$CONTAINERDIR/$NAME/rootfs" | grep -v grep | awk '{print $2}')
    local CONDUCTORNS="/proc/$PID/ns/net"
    local NSDIR=$NETNSDIR/$NAME

    if [ -e CONDUCTORNS ]; then
	    rm $NSDIR
    fi
    ln -sf $CONDUCTORNS $NSDIR

    # Finally we can use iproute2 for configuring network within our network namespace

    local NUM=$(get_next_num "$NAME") # Getting unique interface identifier

    # Building the ip address for the link
    [ -z "$IP4_PREFIX" ] && IP4_PREFIX="${IP4_SUBNET}.$((0x$NUM))." 

    INSIDE_IP4="${IP4_PREFIX}2"
    OUTSIDE_IP4="${IP4_PREFIX}1"
    INSIDE_PEER="${NAME}-inside"
    OUTSIDE_PEER="${NAME}-outside"

    # Subtask 3.c.1
    # Add a veth links (It is a peer link connecting two points) connecting the container's network 
    # namespace to the root(host) namespace. The veth link will have two interfaces.
    # Inside the container, it should use INSIDE_PEER interface and within the host it should use
    # OUTSIDE_PEER interface
    # You should use iproute2 tool (ip command)
    ip link add name $OUTSIDE_PEER type veth peer name $INSIDE_PEER
    ip link set dev $OUTSIDE_PEER up
    ip link set dev $INSIDE_PEER netns $PID up

    # Lesson: By default linux does not forward packets, it only acts as an end host
    # We need to enable packet forwarding capability to forward packets to our containers
    echo 1 > /proc/sys/net/ipv4/ip_forward

    # Subtask 3.c.2
    # Enable the interfaces that you have created within the host and the container
    # You should also enable lo interface within the container (which is disabled by default)
    # In total here 3 interfaces should be enabled
    ip link set dev $OUTSIDE_PEER up
    ip -n $NAME link set dev $INSIDE_PEER 
    ip -n $NAME link set dev lo up


    # Lesson: Configuring addresses and adding routes for the container in the routing table
    # according to the addressing conventions selected above
    ip addr add dev "$OUTSIDE_PEER" "${OUTSIDE_IP4}/${IP4_PREFIX_SIZE}"
    ip -n "$NAME" addr add dev "$INSIDE_PEER" "${INSIDE_IP4}/${IP4_PREFIX_SIZE}"
    ip -n "$NAME" route add "${IP4_SUBNET}/${IP4_FULL_PREFIX_SIZE}" via "$OUTSIDE_IP4" dev "$INSIDE_PEER"


    echo -n "Setting up network '$NAME' with peer ip ${INSIDE_IP4}." || echo "."
    echo " Waiting for interface configuration to settle..."
    echo ""
    # Following command will wait for the link to be ready
    wait_for_dev "$OUTSIDE_PEER" && wait_for_dev "$INSIDE_PEER" "$NAME"

    # In the above configuration we only addressed the communication channel between
    # the container veth interface to the host veth interface. In order to access external
    # network from the host, packets need to be routed to the external network through host.
    # The Host will act like a NAT router for the container traffic.
    if [ "$INTERNET" -eq "1" ]; then

        # Lesson: Making host the default gateway for all packets sent to veth interface with the container
        ip -n "$NAME" route add default via "$OUTSIDE_IP4" dev "$INSIDE_PEER"
        
        # Lesson: This iptable rule will do NAT translation for all packets having source IP same as the 
        # ip of the container
        iptables -t nat -A POSTROUTING -s "${INSIDE_IP4}/${IP4_PREFIX_SIZE}" -o ${DEFAULT_IFC} -j MASQUERADE

        # Lesson: All packets to be forwarded to and fro between default public interface and outside veth interface 
        iptables -A FORWARD -i ${DEFAULT_IFC} -o ${OUTSIDE_PEER} -j ACCEPT
        iptables -A FORWARD -i ${OUTSIDE_PEER} -o ${DEFAULT_IFC} -j ACCEPT

        # Lesson: Setting DNS server statically as per IITB norms
        cp /etc/resolv.conf /etc/resolv.conf.old
        echo "nameserver 8.8.8.8" > /etc/resolv.conf

    fi
    
    # We are exposing a port within the container to be accessible from the public interface
    # Any TCP packet received on the OUTER_PORT of host will be forwarded to the INNER_PORT within
    # the container. This is done to expose a service running within the container to the public
    if [ "$EXPOSE" -eq "1" ]; then
        # Lesson: This iptable rule will replace the ip address and port of any TCP packet received on default interface 
        # destined to OUTER_PORT
        iptables -t nat -A PREROUTING -p tcp -i ${DEFAULT_IFC} --dport ${OUTER_PORT} -j DNAT --to-destination ${INSIDE_IP4}:${INNER_PORT}
        # Lesson: The above rule will only route packets received on the external interface. As a result
        # curl <host-self-ip>:port will not work within the host itself.
        # This iptable rule wiill redirect packets generated 
        # within the host with destination set as hostip:OUTER_PORT to the containers:INNER_PORT. 
        # This will still not work for localhost/127.0.0.1. You will have to send using the host-ip
        iptables -t nat -A OUTPUT -o lo -m addrtype --src-type LOCAL --dst-type LOCAL -p tcp --dport ${OUTER_PORT} -j DNAT --to-destination ${INSIDE_IP4}:${INNER_PORT}
        # Lesson: Allows forwarding of TCP session initiator packets from the public to the container
        iptables -A FORWARD -p tcp -d ${INSIDE_IP4} --dport ${INNER_PORT} -m state --state NEW,ESTABLISHED,RELATED -j ACCEPT
        echo lol
    fi

    rm -rf $NETNSDIR
}

# This function is used to enable peer to peer packet traffic between two containers
peer()
{
    local NAMEA=${1:-}
    local NAMEB=${2:-}
    [ -z "$NAMEA" ] && die "First Container name is required"
    [ -z "$NAMEB" ] && die "Second Container name is required"

    # Lesson: Setting iptable rules to allow two and from traffic between host container interfaces
    iptables -A FORWARD -i "${NAMEA}-outside" -o "${NAMEB}-outside" -j ACCEPT
    iptables -A FORWARD -i "${NAMEB}-outside" -o "${NAMEA}-outside" -j ACCEPT
}


usage()
{
    local FULL=${1:-}

    echo "Usage: $0 <command> [params] [options] [params]"
    echo ""
    echo "Commands:"
    echo "build <img>                           Build image for containers"
    echo "images                                List available images"
    echo "rmi <img>                             Delete image"
    echo "run <img> <cntr> -- [command <args>]  Runs [command] within a new container named <cntr> fron the image named <img>"            
    echo "                                      if no command is given it will run /bin/bash by default"
    echo "ps                                    Show all running containers"
    echo "stop <cntr>                           Stop and delete container"
    echo "exec <cntr> -- [command <args>]       Execute command (default /bin/bash) in a container"
    echo "addnetwork <cntr>                     Adds layer 3 networking to the container"
    echo "peer <cntr> <cntr>                    Allow to container to communicate with each other"
    echo ""

    if [ -z "$FULL" ] ; then
        echo "Use --help to see the list of options."
        exit 1
    fi

    echo "Options:"
    echo "-h, --help                Show this usage text"
    echo ""
    echo ""
    echo "-i, --internet            Allow internet access from the container."
    echo "                          Should be used allongwith addnetwork"
    echo "                          Otherwise makes no sense."
    echo ""
    echo "-e, --expose <inner-port>-<outer-port>"
    echo "                          Expose some port of container (inner)"
    echo "                          as the host's port (outter)"
    echo ""
    echo ""
    exit 1
}

OPTS="hie:"
LONGOPTS="help,internet,expose:"

OPTIONS=$(getopt -o "$OPTS" --long "$LONGOPTS" -- "$@")
[ "$?" -ne "0" ] && usage >&2 || true

eval set -- "$OPTIONS"


while true; do
    arg="$1"
    shift

    case "$arg" in
        -h | --help)
            usage full >&2
            ;;
        -i | --internet)
            INTERNET=1
            ;;
        -e | --expose)
            PORT="$1"
            INNER_PORT=${PORT%-*}
            OUTER_PORT=${PORT#*-}
            EXPOSE=1
            shift
            ;;
        -- )
            break
            ;;
    esac
done

[ "$#" -eq 0 ] && usage >&2

case "$1" in
    build)
        CMD=build
        ;;
    images)
        CMD=images
        ;;
    rmi)
        CMD=remove_image
        ;;
    run)
        CMD=run
        ;;
    ps)
        CMD=show_containers
        ;;
    stop)
        CMD=stop
        ;;
    exec)
        CMD=exec
        ;;
    addnetwork)
        CMD=addnetwork
        ;;
    peer)
        CMD=peer
        ;;
    "help")
        usage full >&2
        ;;
    *)
        usage >&2
        ;;
esac

shift
check_prereq
$CMD "$@"





