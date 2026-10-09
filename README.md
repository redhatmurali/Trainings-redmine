## Install Each Training Project

All commands below assume that Redmine is installed at `/opt/redmine` and runs under the `redmine` Linux user. Change these values if your installation uses a different directory or user.

### 1. Set common variables

```bash
export REDMINE_DIR="/opt/redmine"
export REDMINE_USER="redmine"
```

Confirm that the directory is correct:

```bash
sudo -u "$REDMINE_USER" test -f \
  "$REDMINE_DIR/config/environment.rb" \
  && echo "Redmine directory verified"
```

### 2. Prepare the project files

Clone the repository if you have not already done so:

```bash
git clone https://github.com/redhatmurali/Trainings-redmine.git
cd Trainings-redmine
```

Create a working directory for each training domain and copy its installer and CSV dataset:

```bash
sudo mkdir -p /tmp/redmine-training/{devops,cyber,mikrotik,postgresql,sapbasis,sapfico,sapmm,sapsd}

sudo cp install_devops_project.rb redmine_issues.csv /tmp/redmine-training/devops/

sudo cp install_cyber_project.rb cyber_issues.csv /tmp/redmine-training/cyber/

sudo cp install_mikrotik_project.rb mikrotik_issues.csv /tmp/redmine-training/mikrotik/

sudo cp 'install_postgresql_project (1).rb' 'postgresql_issues (1).csv' /tmp/redmine-training/postgresql/

sudo cp install_sapbasis_project.rb sapbasis_issues.csv /tmp/redmine-training/sapbasis/

sudo cp install_sapfico_project.rb sapfico_issues.csv /tmp/redmine-training/sapfico/

sudo cp install_sapmm_project.rb sapmm_issues.csv /tmp/redmine-training/sapmm/

sudo cp install_sapsd_project.rb sapsd_issues.csv /tmp/redmine-training/sapsd/

sudo chmod -R a+rX /tmp/redmine-training
```

### 3. Run the DevOps installer

```bash
sudo runuser -u "$REDMINE_USER" -- env \
  STUDENTS=student1,student2 \
  INSTRUCTORS=admin \
  bash -c 'cd /opt/redmine && bundle exec rails runner -e production /tmp/redmine-training/devops/install_devops_project.rb'
```

### 4. Run the Cybersecurity installer

```bash
sudo runuser -u "$REDMINE_USER" -- env \
  STUDENTS=student1,student2 \
  INSTRUCTORS=admin \
  bash -c 'cd /opt/redmine && bundle exec rails runner -e production /tmp/redmine-training/cyber/install_cyber_project.rb'
```

### 5. Run the MikroTik installer

```bash
sudo runuser -u "$REDMINE_USER" -- env \
  TEMPLATE=1 \
  INSTRUCTORS=admin \
  bash -c 'cd /opt/redmine && bundle exec rails runner -e production /tmp/redmine-training/mikrotik/install_mikrotik_project.rb'
```

### 6. Run the PostgreSQL installer

```bash
sudo runuser -u "$REDMINE_USER" -- env \
  TEMPLATE=1 \
  INSTRUCTORS=admin \
  bash -c 'cd /opt/redmine && bundle exec rails runner -e production "/tmp/redmine-training/postgresql/install_postgresql_project (1).rb"'
```

This installer is intended for the PostgreSQL Database Engineering training project. Check the Ruby script to confirm how it reads `postgresql_issues (1).csv` and whether it requires additional environment variables.

### 7. Run the SAP BASIS installer

```bash
sudo runuser -u "$REDMINE_USER" -- env \
  TEMPLATE=1 \
  INSTRUCTORS=admin \
  bash -c 'cd /opt/redmine && bundle exec rails runner -e production /tmp/redmine-training/sapbasis/install_sapbasis_project.rb'
```

### 8. Run the SAP FICO installer

```bash
sudo runuser -u "$REDMINE_USER" -- env \
  TEMPLATE=1 \
  INSTRUCTORS=admin \
  bash -c 'cd /opt/redmine && bundle exec rails runner -e production /tmp/redmine-training/sapfico/install_sapfico_project.rb'
```

### 9. Run the SAP MM installer

```bash
sudo runuser -u "$REDMINE_USER" -- env \
  TEMPLATE=1 \
  INSTRUCTORS=admin \
  bash -c 'cd /opt/redmine && bundle exec rails runner -e production /tmp/redmine-training/sapmm/install_sapmm_project.rb'
```

### 10. Run the SAP SD installer

```bash
sudo runuser -u "$REDMINE_USER" -- env \
  TEMPLATE=1 \
  INSTRUCTORS=admin \
  bash -c 'cd /opt/redmine && bundle exec rails runner -e production /tmp/redmine-training/sapsd/install_sapsd_project.rb'
```

## Student and Instructor Configuration

Replace the example logins with users that already exist in Redmine.

For example:

```bash
STUDENTS=alice,bob
INSTRUCTORS=admin
```

Some scripts support `STUDENTS`, while others may support only `INSTRUCTORS` or `TEMPLATE`. Check each script before relying on a variable.

## Verify the Installation

After each script finishes:

1. Open the Redmine web interface.
2. Find the corresponding training project.
3. Confirm that its issues were created or updated as expected.
4. Verify student assignments, instructor permissions, and issue statuses.
5. Review the Redmine production log if an error occurs.

```bash
sudo tail -n 100 /opt/redmine/log/production.log
```

## Important Notes

- These commands run project-provisioning scripts; they do **not** install PostgreSQL Server, SAP software, or MikroTik RouterOS.
- The PostgreSQL training project is distinct from the database that Redmine itself uses.
- The scripts may create, update, or delete project data depending on their implementation. Review them and back up the Redmine database before running them.
- The commands assume the scripts can find their associated CSV files. If a script uses a hard-coded path or expects the CSV in the current directory, adjust the working directory or file path accordingly.
- Validate each command on a staging instance before using it in production.
