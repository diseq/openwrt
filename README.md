# OpenWrt Fluent Bit package feed

This repository builds Fluent Bit for OpenWrt 25.12.3 as an APK package feed and publishes the feed as static files suitable for GitHub Pages.

## Signing key bootstrap

Published feeds must use a stable APK signing key. Do this once from a trusted workstation:

```sh
openssl ecparam -name prime256v1 -genkey -noout -out openwrt-apk-private-key.pem
gh secret set OPENWRT_APK_PRIVATE_KEY_PEM < openwrt-apk-private-key.pem
openssl ec -in openwrt-apk-private-key.pem -pubout -out fluentbit-public-key.pem
```

Keep `openwrt-apk-private-key.pem` private. The GitHub Actions build reads it from the `OPENWRT_APK_PRIVATE_KEY_PEM` repository secret and derives `public-key.pem` for clients.

For local throwaway builds, the secret can be omitted; the OpenWrt SDK will generate an ephemeral key. Do not publish feeds signed with ephemeral keys because devices would need to trust a new key for every build.

## Published feed layout

GitHub Pages should contain one feed per OpenWrt target:

```text
openwrt-25.12.3/
  x86/64/packages/fluentbit/
    fluent-bit-5.0.6-r2.apk
    packages.adb
    index.json
    public-key.pem

  ipq806x/generic/packages/fluentbit/
    fluent-bit-5.0.6-r2.apk
    packages.adb
    index.json
    public-key.pem
```

The device repository URL is the directory containing `packages.adb`; it is not a GitHub Releases download URL.

## Device setup

Replace `<user>` and `<repo>` with the GitHub Pages owner and repository name.

### x86/64

```sh
mkdir -p /etc/apk/keys
wget -O /etc/apk/keys/fluentbit.pem \
  https://<user>.github.io/<repo>/openwrt-25.12.3/x86/64/packages/fluentbit/public-key.pem

echo 'https://<user>.github.io/<repo>/openwrt-25.12.3/x86/64/packages/fluentbit' >> /etc/apk/repositories
apk update
apk add fluent-bit
```

### ipq806x/generic

```sh
mkdir -p /etc/apk/keys
wget -O /etc/apk/keys/fluentbit.pem \
  https://<user>.github.io/<repo>/openwrt-25.12.3/ipq806x/generic/packages/fluentbit/public-key.pem

echo 'https://<user>.github.io/<repo>/openwrt-25.12.3/ipq806x/generic/packages/fluentbit' >> /etc/apk/repositories
apk update
apk add fluent-bit
```
