⭐ Even more premium / institute-style naming
If you're building these as a serious training academy, I would use:
01 — PostgreSQL Database Engineering & Development
Advanced Database Administration, Performance & Application Engineering
02 — DevOps, Cloud & Platform Engineering
Linux, Automation, Containers, Kubernetes & Infrastructure as Code
03 — Cybersecurity & Security Operations Engineering
Network Security, SIEM, Threat Detection, SOC & Incident Response
04 — Enterprise Network Engineering with MikroTik
Routing, Switching, Firewall, VPN, Wireless & Network Security


DEVOPS

https://github.com/redhatmurali/devops.git

# 1. Locate Redmine and its owner
REDMINE_DIR=$(find / -xdev -type f -path '*/lib/redmine/version.rb' 2>/dev/null | head -1 | sed 's#/lib/redmine/version.rb##')
OWNER=$(stat -c %U "$REDMINE_DIR/config/database.yml")
echo "Redmine: $REDMINE_DIR   owner: $OWNER"

# 2. Copy the files where that user can read them
mkdir -p /tmp/devops
cp /root/install_devops_project.rb /root/redmine_issues.csv /tmp/devops/
chmod -R a+rX /tmp/devops

# 3. Run the installer
runuser -l "$OWNER" -s /bin/bash -c "cd $REDMINE_DIR && STUDENTS=alice,bob INSTRUCTORS=admin bundle exec rails runner -e production /tmp/devops/install_devops_project.rb"


runuser -l redmine -s /bin/bash -c "cd /opt/redmine && STUDENTS=student1,student2 bundle exec rails runner -e production /tmp/devops/install_devops_project.rb"


runuser -l redmine -s /bin/bash -c "cd /opt/redmine && TEMPLATE=1 bundle exec rails runner -e production /tmp/devops/install_devops_project.rb"


Cybersecurity 
https://github.com/redhatmurali/devops.git

mkdir -p /tmp/cyber
cp /root/install_cyber_project.rb /root/cyber_issues.csv /tmp/cyber/
chmod -R a+rX /tmp/cyber

runuser -l redmine -s /bin/bash -c "cd /opt/redmine && STUDENTS=student1,student2 INSTRUCTORS=admin bundle exec rails runner -e production /tmp/cyber/install_cyber_project.rb"

runuser -l redmine -s /bin/bash -c "cd /opt/redmine && TEMPLATE=1 bundle exec rails runner -e production /tmp/cyber/install_cyber_project.rb"

runuser -l redmine -s /bin/bash -c "cd /opt/redmine && STUDENTS=student1,student2 bundle exec rails runner -e production /tmp/cyber/install_cyber_project.rb"

runuser -l redmine -s /bin/bash -c "cd /opt/redmine && STUDENTS=ravi,priya bundle exec rails runner -e production /tmp/cyber/install_cyber_project.rb"


MIKROTIK

mkdir -p /tmp/mikrotik
cp /root/install_mikrotik_project.rb /root/mikrotik_issues.csv /tmp/mikrotik/
chmod -R a+rX /tmp/mikrotik

runuser -l redmine -s /bin/bash -c "cd /opt/redmine && TEMPLATE=1 INSTRUCTORS=admin bundle exec rails runner -e production /tmp/mikrotik/install_mikrotik_project.rb"


POSTGRES

mkdir -p /tmp/postgresql
cp /root/install_postgresql_project.rb /root/postgresql_issues.csv /tmp/postgresql/
chmod -R a+rX /tmp/postgresql

runuser -l redmine -s /bin/bash -c "cd /opt/redmine && TEMPLATE=1 INSTRUCTORS=admin bundle exec rails runner -e production /tmp/postgresql/install_postgresql_project.rb"

v3

mkdir -p /tmp/pg && cp /root/install_postgresql_project.rb /root/postgresql_issues.csv /tmp/pg/ && chmod -R a+rX /tmp/pg

# 1. delete the old project
runuser -l redmine -s /bin/bash -c "cd /opt/redmine && bundle exec rails runner -e production 'p = Project.find_by(identifier: \"postgresql-database-engineering-development\"); p && p.destroy; puts \"deleted\"'"

# 2. install the new one
runuser -l redmine -s /bin/bash -c "cd /opt/redmine && TEMPLATE=1 INSTRUCTORS=admin bundle exec rails runner -e production /tmp/pg/install_postgresql_project.rb"



SAP FICO 

mkdir -p /tmp/sapfico
cp /root/install_sapfico_project.rb /root/sapfico_issues.csv /tmp/sapfico/
chmod -R a+rX /tmp/sapfico

runuser -l redmine -s /bin/bash -c "cd /opt/redmine && TEMPLATE=1 INSTRUCTORS=admin bundle exec rails runner -e production /tmp/sapfico/install_sapfico_project.rb"


SAP SD

mkdir -p /tmp/sapsd && cp /root/install_sapsd_project.rb /root/sapsd_issues.csv /tmp/sapsd/ && chmod -R a+rX /tmp/sapsd
runuser -l redmine -s /bin/bash -c "cd /opt/redmine && TEMPLATE=1 INSTRUCTORS=admin bundle exec rails runner -e production /tmp/sapsd/install_sapsd_project.rb"

SAP MM

mkdir -p /tmp/sapmm && cp /root/install_sapmm_project.rb /root/sapmm_issues.csv /tmp/sapmm/ && chmod -R a+rX /tmp/sapmm
runuser -l redmine -s /bin/bash -c "cd /opt/redmine && TEMPLATE=1 INSTRUCTORS=admin bundle exec rails runner -e production /tmp/sapmm/install_sapmm_project.rb"

SAP BASIS

mkdir -p /tmp/sapbasis && cp /root/install_sapbasis_project.rb /root/sapbasis_issues.csv /tmp/sapbasis/ && chmod -R a+rX /tmp/sapbasis
runuser -l redmine -s /bin/bash -c "cd /opt/redmine && TEMPLATE=1 INSTRUCTORS=admin bundle exec rails runner -e production /tmp/sapbasis/install_sapbasis_project.rb"



For Students Active 

runuser -l redmine -s /bin/bash -c "cd /opt/redmine && STUDENTS=santhi bundle exec rails runner -e production /tmp/sapfico/install_sapfico_project.rb"


runuser -l redmine -s /bin/bash -c "cd /opt/redmine && STUDENTS=student1,student2 INSTRUCTORS=admin bundle exec rails runner -e production /tmp/sapbasis/install_sapbasis_project.rb"
