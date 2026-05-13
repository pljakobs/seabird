#a fully integrated boat server

##basis
- rpi CM4 4/5 on a CM4 router baseboard https://mytechcatalog.com/blog/2023/cm4-wrt-a-raspberry-pi-cm4-gigabit-router-baseboard-with-nvme-support
- CM4 broadcomm wifi adapter (wifi0)
- m.2 intel wifi adapter (wifi1)
- CM4 onboard ethernet adapter (eth0)
- router ethernet adapter (eth1)
- CM4 onboard 8/16GB eMMC
- m.2 pci 5g modem (wan0) https://manuals.plus/de/ae/1005008590206803
- 1TB NVMe
- ideal distribution: Fedora using bootc 
- additional services need to be configured using quadlets
- the eMMC is exclusively used for low write load data (images, boot etc)
- the NVMe is btrfs formatted and used for all live data including persistent logging
- 

##connectivity
- internet via wifi, wan or eth, best adapters need to be decided 
- open a local private network spanning the remaining wifi and lan adapters natted and firewalled to the three upstream links
- must be able to forward wifi captive portal for initial login, other nodes will leverage the same connection

##services
- signal-K
- influxdb
- grafana
- nextcloud

##data collection
- signal-K reads data from the nmea2000 bus via an esp32 providing a udp stream

