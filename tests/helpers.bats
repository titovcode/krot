#!/usr/bin/env bats

setup() {
    source "${BATS_TEST_DIRNAME}/../krot/files/usr/lib/helpers.sh"
}

# ============================================================
# is_ipv4
# ============================================================

@test "is_ipv4: valid addresses" {
    run is_ipv4 "192.168.1.1"
    [ "$status" -eq 0 ]

    run is_ipv4 "0.0.0.0"
    [ "$status" -eq 0 ]

    run is_ipv4 "255.255.255.255"
    [ "$status" -eq 0 ]

    run is_ipv4 "10.0.0.1"
    [ "$status" -eq 0 ]

    run is_ipv4 "1.2.3.4"
    [ "$status" -eq 0 ]
}

@test "is_ipv4: invalid addresses" {
    run is_ipv4 "256.1.1.1"
    [ "$status" -ne 0 ]

    run is_ipv4 "1.2.3"
    [ "$status" -ne 0 ]

    run is_ipv4 "1.2.3.4.5"
    [ "$status" -ne 0 ]

    run is_ipv4 "abc.def.ghi.jkl"
    [ "$status" -ne 0 ]

    run is_ipv4 ""
    [ "$status" -ne 0 ]

    run is_ipv4 "1.2.3.4 "
    [ "$status" -ne 0 ]
}

# ============================================================
# is_ipv4_cidr
# ============================================================

@test "is_ipv4_cidr: valid CIDR" {
    run is_ipv4_cidr "192.168.1.0/24"
    [ "$status" -eq 0 ]

    run is_ipv4_cidr "10.0.0.0/8"
    [ "$status" -eq 0 ]

    run is_ipv4_cidr "0.0.0.0/0"
    [ "$status" -eq 0 ]

    run is_ipv4_cidr "255.255.255.255/32"
    [ "$status" -eq 0 ]

    run is_ipv4_cidr "172.16.0.0/12"
    [ "$status" -eq 0 ]
}

@test "is_ipv4_cidr: rejects leading zeros in prefix" {
    run is_ipv4_cidr "192.168.1.0/00"
    [ "$status" -ne 0 ]

    run is_ipv4_cidr "192.168.1.0/01"
    [ "$status" -ne 0 ]

    run is_ipv4_cidr "192.168.1.0/09"
    [ "$status" -ne 0 ]
}

@test "is_ipv4_cidr: invalid CIDR" {
    run is_ipv4_cidr "192.168.1.0/33"
    [ "$status" -ne 0 ]

    run is_ipv4_cidr "192.168.1.0/-1"
    [ "$status" -ne 0 ]

    run is_ipv4_cidr "192.168.1.0"
    [ "$status" -ne 0 ]

    run is_ipv4_cidr "192.168.1.0/abc"
    [ "$status" -ne 0 ]
}

# ============================================================
# is_domain
# ============================================================

@test "is_domain: valid domains" {
    run is_domain "example.com"
    [ "$status" -eq 0 ]

    run is_domain "sub.domain.example.com"
    [ "$status" -eq 0 ]

    run is_domain "a.b"
    [ "$status" -eq 0 ]

    run is_domain "google.com"
    [ "$status" -eq 0 ]
}

@test "is_domain: invalid domains" {
    run is_domain ""
    [ "$status" -ne 0 ]

    run is_domain "-example.com"
    [ "$status" -ne 0 ]

    run is_domain "example-.com"
    [ "$status" -ne 0 ]

    run is_domain "EXAMPLE.COM"
    [ "$status" -ne 0 ]

    run is_domain "example.com "
    [ "$status" -ne 0 ]
}

# ============================================================
# comma_string_to_json_array
# ============================================================

@test "comma_string_to_json_array: empty input returns empty array" {
    run comma_string_to_json_array ""
    [ "$output" = "[]" ]
}

@test "comma_string_to_json_array: single value" {
    run comma_string_to_json_array "example.com"
    [ "$output" = '["example.com"]' ]
}

@test "comma_string_to_json_array: multiple values" {
    run comma_string_to_json_array "example.com,google.com,github.com"
    [ "$output" = '["example.com","google.com","github.com"]' ]
}

@test "comma_string_to_json_array: escapes double quotes" {
    run comma_string_to_json_array 'value"with"quotes'
    [ "$output" = '["value\"with\"quotes"]' ]
}

@test "comma_string_to_json_array: escapes backslashes" {
    run comma_string_to_json_array 'path\to\file'
    [ "$output" = '["path\\to\\file"]' ]
}

# ============================================================
# normalize_port_number
# ============================================================

@test "normalize_port_number: valid ports" {
    run normalize_port_number "80"
    [ "$output" = "80" ]

    run normalize_port_number "443"
    [ "$output" = "443" ]

    run normalize_port_number "1"
    [ "$output" = "1" ]

    run normalize_port_number "65535"
    [ "$output" = "65535" ]

    run normalize_port_number "  8080  "
    [ "$output" = "8080" ]
}

@test "normalize_port_number: invalid ports" {
    run normalize_port_number "0"
    [ "$status" -ne 0 ]

    run normalize_port_number "65536"
    [ "$status" -ne 0 ]

    run normalize_port_number "abc"
    [ "$status" -ne 0 ]

    run normalize_port_number ""
    [ "$status" -ne 0 ]
}

# ============================================================
# is_min_package_version
# ============================================================

@test "is_min_package_version: version meets requirement" {
    run is_min_package_version "1.2.0" "1.1.0"
    [ "$status" -eq 0 ]

    run is_min_package_version "1.2.0" "1.2.0"
    [ "$status" -eq 0 ]

    run is_min_package_version "2.0.0" "1.9.9"
    [ "$status" -eq 0 ]
}

@test "is_min_package_version: version below requirement" {
    run is_min_package_version "1.1.0" "1.2.0"
    [ "$status" -ne 0 ]

    run is_min_package_version "1.0.0" "1.1.0"
    [ "$status" -ne 0 ]
}

# ============================================================
# is_shadowsocks_userinfo_format
# ============================================================

@test "is_shadowsocks_userinfo_format: valid" {
    run is_shadowsocks_userinfo_format "method:password"
    [ "$status" -eq 0 ]

    run is_shadowsocks_userinfo_format "aes-256-gcm:secret"
    [ "$status" -eq 0 ]

    run is_shadowsocks_userinfo_format "method:password:extra"
    [ "$status" -eq 0 ]
}

@test "is_shadowsocks_userinfo_format: invalid" {
    run is_shadowsocks_userinfo_format ""
    [ "$status" -ne 0 ]

    run is_shadowsocks_userinfo_format "nopassword"
    [ "$status" -ne 0 ]

    run is_shadowsocks_userinfo_format ":password"
    [ "$status" -ne 0 ]
}
