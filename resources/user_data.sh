#!/usr/bin/bash

prereq() {
    sudo apt-get update && sudo apt-get install -y wireguard bind9
    sudo sed -i '/net.ipv4.ip_forward=1/s/#//' /etc/sysctl.conf && sudo sysctl -p
}

chmod() {
    sudo chmod 600 $1 $2 $3
}

configuration() {
    declare -a peers=("$@")

    wg genkey | sudo tee /etc/wireguard/server_priv.key | wg pubkey | sudo tee /etc/wireguard/server_pub.key
    SERVER_PRIV=$(sudo cat /etc/wireguard/server_priv.key)
    SERVER_PUB=$(sudo cat /etc/wireguard/server_pub.key)
    PUBLIC_IP=$(dig +short myip.opendns.com @resolver1.opendns.com)

    chmod "/etc/wireguard/server_priv.key" "/etc/wireguard/server_pub.key"

    cat <<-EOF | sudo tee /etc/wireguard/wg0.conf
[Interface]
Address = 10.10.10.1/29
ListenPort = 51820
PrivateKey = $SERVER_PRIV
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o enX0 -j MASQUERADE; iptables -I INPUT -p tcp --dport 22 -j ACCEPT
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o enX0 -j MASQUERADE; iptables -D INPUT -p tcp --dport 22 -j ACCEPT
DNS = 10.10.10.1

#### Create NAT table in order to forward traffic to public internet
# -A FORWARD: The FORWARD chain is used for packets that are being routed through the server (i.e., packets that aren't intended for the server itself but are passing through to other devices).
# -A POSTROUTING: This appends the rule to the POSTROUTING chain in the nat table. The POSTROUTING chain handles packets that are leaving the server (after they’ve been routed, but before they go out to the network).
EOF

    index=2
    local web_index

    for peer in "${peers[@]}"; do
        wg genkey | sudo tee /etc/wireguard/peer_${peer}_priv.key | wg pubkey | sudo tee /etc/wireguard/peer_${peer}_pub.key
        wg genpsk | sudo tee /etc/wireguard/peer_${peer}_psk.key

        chmod "/etc/wireguard/peer_${peer}_priv.key" "/etc/wireguard/peer_${peer}_pub.key" "/etc/wireguard/peer_${peer}_psk.key"

        PEER_PUB=$(sudo cat /etc/wireguard/peer_${peer}_pub.key)
        PEER_PSK=$(sudo cat /etc/wireguard/peer_${peer}_psk.key)
        PEER_PRIV=$(sudo cat /etc/wireguard/peer_${peer}_priv.key)

        cat <<-EOF | sudo tee /etc/wireguard/peer_${peer}.conf
[Interface]
Address = 10.10.10.$index/29
PrivateKey = $PEER_PRIV
DNS = 10.10.10.1

[Peer]
PublicKey = $SERVER_PUB
PresharedKey = $PEER_PSK
Endpoint = $PUBLIC_IP:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
        cat <<-EOF | sudo tee -a /etc/wireguard/wg0.conf

[Peer]
### peer_${peer} ###
PublicKey = $PEER_PUB
PresharedKey = $PEER_PSK
AllowedIPs = 0.0.0.0/0
EOF

        [[ $peer == "web" ]] && web_index=$index

        (( index++ ))
    done

    cat <<EOF | sudo tee /etc/bind/db.local.test
\$TTL 86400
@       IN      SOA     ns.local.test.  hostmaster.local.test. (
                        2025021801  ; version
                        86400       ; refresh
                        7200        ; retry
                        3600000     ; expire
                        86400 )     ; minimum TTL

; Nameservers
        IN      NS      ns.local.test.

; Records
        IN      A       10.10.10.$web_index
ns      IN      A       10.10.10.1

; CNAME
www     IN      CNAME   local.test.
EOF

    cat <<EOF | sudo tee /etc/bind/db.local.test.arpa
\$TTL 86400
@       IN      SOA     ns.local.test.  hostmaster.local.test. (
                        2025021801  ; version
                        86400       ; refresh
                        7200        ; retry
                        3600000     ; expire
                        86400 )     ; minimum TTL

; Namerservers
        IN      NS      ns.local.test.

; Resolve IP address to FQDN Pointers (PTR)
$web_index       IN      PTR     www.local.test.
1       IN      PTR     ns.local.test.
EOF

    cat <<EOF | sudo tee /etc/bind/named.conf.options
// ACL names
acl vpn-network { 10.10.10.0/29; };
options {
    directory "/var/cache/bind";
    
    // If there is a firewall between you and nameservers you want
    // to talk to, you may need to fix the firewall to allow multiple
    // ports to talk.  See http://www.kb.cert.org/vuls/id/800113
    
    // If your ISP provided one or more IP addresses for stable 
    // nameservers, you probably want to use them as forwarders.  
    // Uncomment the following block, and insert the addresses replacing
    // the all-0's placeholder.
    
    // Defines where to forward unresolved queries:
    // forwarders {
    //  0.0.0.0;
    // };
    
    //========================================================================
    // If BIND logs error messages about the root key being expired,
    // you will need to update your keys.  See https://www.isc.org/bind-keys
    //========================================================================
    dnssec-validation auto;

    // You don't have to specify port for default 53
    listen-on port 53 { 10.10.10.1; };

    // Defines range of IP addresses from which the server will process requests:
    allow-query { vpn-network; };

    // Defines from which IP addresses can process reqursive queries:
    allow-recursion { vpn-network; };

    // Specifies to which secondaries DNS servers to transfer the DNS records:
    allow-transfer { none; };
    allow-update { none; };

    version none;
    hostname none;
    server-id none;
};
EOF

    cat <<EOF | sudo tee /etc/bind/named.conf.local
//
// Do any local configuration here
//

// Consider adding the 1918 zones here, if they are not used in your
// organization
//include "/etc/bind/zones.rfc1918";

zone "local.test" {
    type master;
    file "/etc/bind/db.local.test";
};

zone "29-10.10.10.in-addr.arpa" {
    type master;
    file "/etc/bind/db.local.test.arpa";
};
EOF
}

initiation() {
    sudo systemctl stop named.service
    sudo systemctl stop wg-quick@wg0.service
    #sudo systemctl enable --now wg-quick@wg0
    #sudo systemctl restart named.service
}

prereq
configuration "phone" "docker" "web"
initiation