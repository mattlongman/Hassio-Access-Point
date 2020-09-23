# Changelog

## [0.1.1] - 2020-09-23

### Removed
- Remove unnecessary docker privileges (SYS_ADMIN, SYS_RAWIO, SYS_TIME, SYS_NICE) from config.json
- Remove full access ("full_access": true) from config.json

## [0.1.0] - 2020-09-23

First release.

**Note**: This project was forked from [https://github.com/davidramosweb/hassio-addons](https://github.com/davidramosweb/hassio-addons/tree/f932481fa0503bf0f0b3f8a705b40780d3fe469a). I've submitted a lot of the functionality of this project back as a PR, but some of the extra stuff is outside the scope of a hostapd addon, so I'll leave it here for now as a more expandable hass.io access point addon.

### Added
- Allow hidden SSIDs (as per https://github.com/davidramosweb/hassio-addons/pull/6)
- Allow specification of interface name (defaults to wlan0) (as per https://github.com/davidramosweb/hassio-addons/issues/11)
- Added MAC address filtering
- Add DHCP server (dnsmasq)
- Enable AppArmor
- Add a basic icon/logo. Can do better...

### Changed
- Enabled wmm ("QoS support, also required for full speed on 802.11n/ac/ax") - have tested on mutiple RPIs, but needs further compatibility testing, and potentially moving option to addon config
- Remove interfaces file. Now generate it with specified interface name
- Remove /dev/mem mapping in config.json. Don't need memory access
- Remove RW access to config, ssl, addons, share, backup. Not required

### Fixed
- Remove networkmanager, net-tools, sudo versions (as per https://github.com/davidramosweb/hassio-addons/pull/15, https://github.com/davidramosweb/hassio-addons/pull/8, https://github.com/davidramosweb/hassio-addons/issues/14, https://github.com/davidramosweb/hassio-addons/issues/13)
- Corrected broadcast address (as per https://github.com/davidramosweb/hassio-addons/pull/1)