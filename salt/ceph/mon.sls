# vi: set ft=yaml.jinja :

{% set cluster = salt['grains.get']('environment','ceph') -%}
{% set fsid = salt['pillar.get']('ceph:global:fsid') -%}
{% set host = salt['config.get']('host') -%}
{% set ip = salt['network.interfaces']()['eth0']['inet'][0]['address'] -%}
{% set admin_keyring = '/etc/ceph/' + cluster + '.client.admin.keyring' -%}
{% set bootstrap_osd_keyring = '/var/lib/ceph/bootstrap-osd/' + cluster + '.keyring' -%}
{% set secret = '/var/lib/ceph/tmp/' + cluster + '.mon.keyring' -%}
{% set monmap = '/var/lib/ceph/tmp/' + cluster + 'monmap' -%}

include:
  - .ceph

{{ admin_keyring }}:
  cmd.run:
    - name: echo "Keyring doesn't exists"
    - unless: test -f {{ admin_keyring }}

{% for mon in salt['mine.get']('roles:ceph-mon','network.ip_addrs','grain' ) -%}

cp.get_file {{mon}}{{ admin_keyring }}:
  module.wait:
    - name: cp.get_file
    - path: salt://{{ mon }}/files{{ admin_keyring }}
    - dest: {{ admin_keyring }}
    - watch:
      - cmd: {{ admin_keyring }}

{% endfor -%}

get_mon_secret:
  cmd.run:
    - name: ceph auth get mon. -o {{ secret }}
    - onlyif: test -f {{ admin_keyring }}
    - unless: test -f {{ secret }}
    - timeout: 5

get_mon_map:
  cmd.run:
    - name: ceph mon getmap -o {{ monmap }}
    - onlyif: test -f {{ admin_keyring }}
    - unless: test -f {{ monmap }}
    - timeout: 5

gen_mon_secret:
  cmd.run:
    - name: ceph-authtool --create-keyring {{ secret }} --gen-key -n mon. --cap mon 'allow *'
    - unless: test -f /var/lib/ceph/mon/{{ cluster }}-{{ host }}/keyring || test -f {{ secret }}

gen_admin_keyring:
  cmd.run:
    - name: ceph-authtool --create-keyring {{ admin_keyring }} --gen-key -n client.admin --set-uid=0 --cap mon 'allow *' --cap osd 'allow *' --cap mds 'allow'
    - unless: test -f /var/lib/ceph/mon/{{ cluster }}-{{ host }}/keyring || test -f {{ admin_keyring }}

import_keyring:
  cmd.wait:
    - name: ceph-authtool {{ secret }} --import-keyring {{ admin_keyring }}
    - unless: ceph-authtool {{ secret }} --list | grep '^\[client.admin\]'
    - watch:
      - cmd: gen_mon_secret
      - cmd: gen_admin_keyring

cp.push {{ admin_keyring }}:
  module.wait:
    - name: cp.push
    - path: {{ admin_keyring }}
    - watch:
      - cmd: gen_admin_keyring

cp.push {{ bootstrap_osd_keyring }}:
  module.wait:
    - name: cp.push
    - path: {{ bootstrap_osd_keyring }}
    - watch:
      - cmd: gen_admin_keyring

gen_mon_map:
  cmd.run:
    - name: monmaptool --create --add {{ host }} {{ ip }} --fsid {{ fsid }} {{ monmap }}
    - unless: test -f {{ monmap }}

populate_mon:
  cmd.wait:
    - name: ceph-mon --mkfs -i {{ host }} --monmap {{ monmap }} --keyring {{ secret }}
    - watch:
      - cmd: gen_mon_map

start_mon:
  cmd.run:
    - name: start ceph-mon id={{ host }}
    - unless: status ceph-mon id={{ host }}
    - require:
      - cmd: populate_mon

add_mon:
  cmd.wait:
    - name: ceph mon add {{ host }} {{ ip }}
    - timeout: 5
    - watch:
      - cmd: start_mon

