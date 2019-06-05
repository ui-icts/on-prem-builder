#!/bin/bash
systemctl stop hab-sup-default
rm -rf /hab/sup/default/specs/builder-*
rm -rf /hab/pkgs/habitat
