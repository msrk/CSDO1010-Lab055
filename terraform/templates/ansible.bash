#!/usr/bin/env bash
set -euo pipefail

# Ensure we are able to install packages.
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -y
sudo apt-get upgrade -y
sudo apt-get install -y ansible

mkdir -p Lab05-ansible/{inventory,roles/{base,web}/{tasks,templates,handlers,defaults}}
cd Lab05-ansible

cat <<EOF > inventory/hosts.ini
# inventory/hosts.ini
[web]
localhost ansible_connection=local ansible_python_interpreter=/usr/bin/python3
EOF

cat <<EOF > site.yml
# site.yml
- hosts: web
  become: true
  roles:
    - base
    - web
EOF

cat <<EOF > roles/base/tasks/main.yml
- name: Set timezone
  ansible.builtin.timezone:
    name: "UTC"

- name: Install required packages
  ansible.builtin.apt:
    name: ["vim","curl","nginx","ca-certificates","tar"]
    state: present
    update_cache: true

- name: Ensure deploy user exists
  ansible.builtin.user:
    name: "app"
    system: true
    create_home: false

- name: Create web root
  ansible.builtin.file:
    path: "/var/www/app"
    state: directory
    owner: "app"
    group: "app"
    mode: "0755"
EOF

cat <<EOF > roles/web/tasks/main.yml
# roles/web/tasks/main.yml
- name: Get latest release metadata
  ansible.builtin.uri:
    url: "https://api.github.com/repos/interrupt-software/happy-animals/releases/latest"
    return_content: true
    headers: { Accept: "application/vnd.github+json" }
  register: release
  changed_when: false

- name: Set release tag
  ansible.builtin.set_fact:
    ha_tag: "{{ release.json.tag_name }}"

- name: Check if version already deployed
  ansible.builtin.stat:
    path: "/var/www/app/.version_{{ ha_tag }}"
  register: stamp

- name: Download release
  ansible.builtin.get_url:
    url: "https://github.com/interrupt-software/happy-animals/archive/refs/tags/{{ ha_tag }}.tar.gz"
    dest: "/tmp/happy-animals-{{ ha_tag }}.tar.gz"
    mode: "0644"
  when: not stamp.stat.exists

- name: Clean web root if updating
  ansible.builtin.file:
    path: "/var/www/app"
    state: absent
  when: not stamp.stat.exists

- name: Recreate web root
  ansible.builtin.file:
    path: "/var/www/app"
    state: directory
    owner: "app"
    group: "app"
    mode: "0755"
  when: not stamp.stat.exists

- name: Extract site files
  ansible.builtin.unarchive:
    src: "/tmp/happy-animals-{{ ha_tag }}.tar.gz"
    dest: "/var/www/app"
    remote_src: true
    extra_opts: ["--strip-components=1"]
    owner: "app"
    group: "app"
  when: not stamp.stat.exists

- name: Mark version deployed
  ansible.builtin.file:
    path: "/var/www/app/.version_{{ ha_tag }}"
    state: touch
    owner: "app"
    group: "app"
    mode: "0644"
  when: not stamp.stat.exists

- name: Configure Nginx site
  ansible.builtin.template:
    src: "nginx.conf.j2"
    dest: "/etc/nginx/sites-available/app.conf"
    mode: "0644"
  notify: Reload nginx

- name: Enable Nginx site
  ansible.builtin.file:
    src: "/etc/nginx/sites-available/app.conf"
    dest: "/etc/nginx/sites-enabled/app.conf"
    state: link
    force: true
  notify: Reload nginx

- name: Ensure Nginx running
  ansible.builtin.service:
    name: "nginx"
    state: started
    enabled: true
EOF

cat <<EOF > roles/web/templates/nginx.conf.j2
server {
  listen 80;
  server_name _;
  root /var/www/app;
  index index.html;
  location /health { return 200 'ok'; add_header Content-Type text/plain; }
}
EOF

cat <<EOF > roles/web/handlers/main.yml
- name: Reload nginx
  ansible.builtin.service:
    name: nginx
    state: reloaded
EOF

ansible-playbook -i inventory/hosts.ini site.yml

sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t && sudo systemctl reload nginx

exit 0