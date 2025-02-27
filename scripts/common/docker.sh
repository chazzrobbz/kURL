
function init_daemon_json() {
    if [ -f /etc/docker/daemon.json ]; then
        return
    fi

    mkdir -p /etc/docker

    # Change cgroup driver to systemd
    # Docker uses cgroupfs by default to manage cgroup. On distributions using systemd,
    # i.e. RHEL and Ubuntu, this causes issues because there are now 2 seperate ways
    # to manage resources. For more info see the link below.
    # https://github.com/kubernetes/kubeadm/issues/1394#issuecomment-462878219
    #
    if [ ! -f /var/lib/kubelet/kubeadm-flags.env ]; then
        cat > /etc/docker/daemon.json <<EOF
{
    "log-driver": "json-file",
    "log-opts": {"max-size": "10m"},
    "exec-opts": ["native.cgroupdriver=systemd"]
}
EOF
    else
        cat > /etc/docker/daemon.json <<EOF
{
    "log-driver": "json-file",
    "log-opts": {"max-size": "10m"}
}
EOF
    fi

    mkdir -p /etc/systemd/system/docker.service.d
}

function install_docker() {
    if [ "$SKIP_DOCKER_INSTALL" != "1" ]; then
        if [ -z "$DOCKER_VERSION" ]; then
            printf "${RED}The installer did not specify a version of Docker to include, but is required by all kURL installation scripts currently. The latest supported version of Docker will be installed.${NC}\n"
            DOCKER_VERSION="19.03.4"
        fi
        init_daemon_json
        docker_get_host_packages_online "$DOCKER_VERSION"
        docker_install
        systemctl enable docker
        systemctl start docker
        check_docker_storage_driver "$HARD_FAIL_ON_LOOPBACK"
    fi

    # NOTE: this will not remove the proxy
    if [ -z "$PRESERVE_DOCKER_CONFIG" ] && [ -n "$PROXY_ADDRESS" ]; then
        docker_configure_proxy
    fi
}

function restart_docker() {
    systemctl daemon-reload
    systemctl restart docker
}

function docker_install() {
    case "$LSB_DIST" in
    centos|rhel|ol)
        if [ "${DIST_VERSION_MAJOR}" = "8" ] && ! is_docker_version_supported ; then
            rpm_force_install_host_packages "${DIR}/packages/docker/${DOCKER_VERSION}" "docker-ce-${DOCKER_VERSION}" "docker-ce-cli-${DOCKER_VERSION}"
            export DID_INSTALL_DOCKER=1
        fi
        ;;
    esac

    if [ "${DID_INSTALL_DOCKER}" != "1" ]; then
        install_host_packages "${DIR}/packages/docker/${DOCKER_VERSION}" "docker-ce-${DOCKER_VERSION}" "docker-ce-cli-${DOCKER_VERSION}"
        export DID_INSTALL_DOCKER=1
    fi

    cp "${DIR}/packages/docker/${DOCKER_VERSION}/runc" "$(which runc)"
}

function is_docker_version_supported() {
    case "$LSB_DIST" in
    centos|rhel|ol)
        if [ "${DIST_VERSION_MAJOR}" = "8" ]; then
            if [ "$DOCKER_VERSION" = "18.09.8" ] || [ "$DOCKER_VERSION" = "19.03.4" ] || [ "$DOCKER_VERSION" = "19.03.10" ]; then
                return 1
            fi
        fi
        ;;
    esac

    return 0
}

function uninstall_docker() {
    if ! commandExists docker || [ -n "$DOCKER_VERSION" ] || [ -z "$CONTAINERD_VERSION" ]; then
        return
    fi

    docker rm -f $(docker ps -a -q) || true
    # The rm -rf /var/lib/docker command below may fail with device busy error, so remove as much
    # data as possible now
    docker system prune --all --volumes --force

    logStep "Uninstalling Docker..."
    case "$LSB_DIST" in
        ubuntu)
            export DEBIAN_FRONTEND=noninteractive
            dpkg --purge docker-ce docker-ce-cli
            ;;

        centos|rhel|amzn|ol)
            local dockerPackages=("docker-ce" "docker-ce-cli")
            if rpm -qa | grep -q 'docker-ce-rootless-extras'; then
                dockerPackages+=("docker-ce-rootless-extras")
            fi
            rpm --erase ${dockerPackages[@]}
            ;;
    esac

    rm -rf /var/lib/docker || true
    rm -f /var/run/dockershim.sock
    rm -f /var/run/docker.sock
    echo "Docker successfully uninstalled."

    # With the internal loadbalancer it may take a minute or two after starting kubelet before
    # kubectl commands work
    local node=$(hostname | tr '[:upper:]' '[:lower:]')
    try_5m kubectl uncordon "$node" --kubeconfig=/etc/kubernetes/kubelet.conf

}

check_docker_storage_driver() {
    if [ "$BYPASS_STORAGEDRIVER_WARNINGS" = "1" ]; then
        return
    fi

    _driver=$(docker info 2>/dev/null | grep 'Storage Driver' | awk '{print $3}' | awk -F- '{print $1}')
    if [ "$_driver" = "devicemapper" ] && docker info 2>/dev/null | grep -Fqs 'Data loop file:' ; then
        printf "${RED}The running Docker daemon is configured to use the 'devicemapper' storage driver \
in loopback mode.\nThis is not recommended for production use. Please see to the following URL for more \
information.\n\nhttps://help.replicated.com/docs/kb/developer-resources/devicemapper-warning/.${NC}\n\n\
"
        # HARD_FAIL_ON_LOOPBACK
        if [ -n "$1" ]; then
            printf "${RED}Please configure a recommended storage driver and try again.${NC}\n\n"
            exit 1
        fi

        printf "Do you want to proceed anyway? "
        if ! confirmN; then
            exit 0
        fi
    fi
}

docker_configure_proxy() {
    local previous_proxy=$(docker info 2>/dev/null | grep -i 'Http Proxy:' | awk '{ print $NF }')
    local previous_no_proxy=$(docker info 2>/dev/null | grep -i 'No Proxy:' | awk '{ print $NF }')
    if [ "$PROXY_ADDRESS" = "$previous_proxy" ] && [ "$NO_PROXY_ADDRESSES" = "$previous_no_proxy" ]; then
        return
    fi

    mkdir -p /etc/systemd/system/docker.service.d
    local file=/etc/systemd/system/docker.service.d/http-proxy.conf

    echo "# Generated by kURL" > $file
    echo "[Service]" >> $file

    if echo "$PROXY_ADDRESS" | grep -q "^https"; then
        echo "Environment=\"HTTPS_PROXY=${PROXY_ADDRESS}\" \"NO_PROXY=${NO_PROXY_ADDRESSES}\"" >> $file
    else
        echo "Environment=\"HTTP_PROXY=${PROXY_ADDRESS}\" \"NO_PROXY=${NO_PROXY_ADDRESSES}\"" >> $file
    fi

    restart_docker
}

function docker_get_host_packages_online() {
    local version="$1"

    if [ "$AIRGAP" != "1" ] && [ -n "$DIST_URL" ]; then
        rm -rf $DIR/packages/docker/${version} # Cleanup broken/incompatible packages from failed runs

        local package="docker-${version}.tar.gz"
        package_download "${package}"
        tar xf "$(package_filepath "${package}")"
        # rm docker-${version}.tar.gz
    fi
}

function containerd_get_host_packages_online() {
    local version="$1"

    if [ "$AIRGAP" != "1" ] && [ -n "$DIST_URL" ]; then
        rm -rf $DIR/packages/containerd/${version} # Cleanup broken/incompatible packages from failed runs

        local package="containerd-${version}.tar.gz"
        package_download "${package}" $CONTAINERD_S3_OVERRIDE
        tar xf "$(package_filepath "${package}")"
        # rm containerd-${version}.tar.gz
    fi
}

function canonical_image_name() {
    local image="$1"
    if echo "$image" | grep -vq '/' ; then
        image="library/$image"
    fi
    if echo "$image" | awk -F'/' '{print $1}' | grep -vq '\.' ; then
        image="docker.io/$image"
    fi
    if echo "$image" | grep -vq ':' ; then
        image="$image:latest"
    fi
    echo "$image"
}
