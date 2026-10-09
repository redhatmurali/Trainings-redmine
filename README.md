# Redmine Training Projects

A collection of Ruby on Rails automation scripts and CSV issue datasets for creating structured, hands-on training projects in Redmine.

This repository supports practical training environments for DevOps, Cybersecurity, MikroTik Networking, PostgreSQL Database Engineering, and SAP functional and technical modules.

## Training Domains

| Training Domain | Installer Script | CSV Dataset |
|---|---|---|
| DevOps & Platform Engineering | `install_devops_project.rb` | `redmine_issues.csv` |
| Cybersecurity & Security Operations | `install_cyber_project.rb` | `cyber_issues.csv` |
| MikroTik Network Engineering | `install_mikrotik_project.rb` | `mikrotik_issues.csv` |
| PostgreSQL Database Engineering | `install_postgresql_project (1).rb` | `postgresql_issues (1).csv` |
| SAP BASIS Administration | `install_sapbasis_project.rb` | `sapbasis_issues.csv` |
| SAP FICO | `install_sapfico_project.rb` | `sapfico_issues.csv` |
| SAP Materials Management (MM) | `install_sapmm_project.rb` | `sapmm_issues.csv` |
| SAP Sales and Distribution (SD) | `install_sapsd_project.rb` | `sapsd_issues.csv` |

## Repository Structure

```text
Trainings-redmine/
├── README.md
├── install_devops_project.rb
├── install_cyber_project.rb
├── install_mikrotik_project.rb
├── install_postgresql_project (1).rb
├── install_sapbasis_project.rb
├── install_sapfico_project.rb
├── install_sapmm_project.rb
├── install_sapsd_project.rb
├── redmine_issues.csv
├── cyber_issues.csv
├── mikrotik_issues.csv
├── postgresql_issues (1).csv
├── redmine_issues.csv
├── sapbasis_issues.csv
├── sapfico_issues.csv
├── sapmm_issues.csv
└── sapsd_issues.csv
```

The PostgreSQL files currently contain the suffix `(1)` in their names. The commands below rename copies to simpler names for execution.

## Prerequisites

- A working Redmine installation.
- Ruby, Rails, and the required gems compatible with that Redmine installation.
- Access to the Redmine production environment and database.
- A Linux user that owns or manages the Redmine application, assumed here to be `redmine`.
- Redmine student and instructor accounts created before assignment.
- The required installer scripts and their corresponding CSV datasets.

These scripts provision Redmine training projects. They do not install PostgreSQL Server, SAP software, or MikroTik RouterOS.

## 1. Locate the Redmine Installation

Find the Redmine application directory:

```bash
REDMINE_DIR=$(find / -xdev -type f \
  -path '*/lib/redmine/version.rb' \
  2>/dev/null | head -n 1 | \
  sed 's#/lib/redmine/version.rb##')

echo "Redmine directory: $REDMINE_DIR"
```

If the result is empty or incorrect, locate the installation manually.

The commands in this README assume:

```text
Redmine directory: /opt/redmine
Redmine Linux user: redmine
```

Confirm the installation:

```bash
sudo test -f /opt/redmine/config/environment.rb \
  && echo "Redmine installation found"
```

## 2. Prepare the Training Files

Clone the repository if it is not already available on the server:

```bash
git clone https://github.com/redhatmurali/Trainings-redmine.git
cd Trainings-redmine
```

Create working directories:

```bash
sudo mkdir -p /tmp/devops
sudo mkdir -p /tmp/cyber
sudo mkdir -p /tmp/mikrotik
sudo mkdir -p /tmp/pg
sudo mkdir -p /tmp/sapbasis
sudo mkdir -p /tmp/sapfico
sudo mkdir -p /tmp/sapmm
sudo mkdir -p /tmp/sapsd
```

Copy the installers and datasets:

```bash
sudo cp install_devops_project.rb redmine_issues.csv /tmp/devops/

sudo cp install_cyber_project.rb cyber_issues.csv /tmp/cyber/

sudo cp install_mikrotik_project.rb mikrotik_issues.csv /tmp/mikrotik/

sudo cp 'install_postgresql_project (1).rb' /tmp/pg/install_postgresql_project.rb

sudo cp 'postgresql_issues (1).csv' /tmp/pg/postgresql_issues.csv

sudo cp install_sapbasis_project.rb sapbasis_issues.csv /tmp/sapbasis/

sudo cp install_sapfico_project.rb sapfico_issues.csv /tmp/sapfico/

sudo cp install_sapmm_project.rb sapmm_issues.csv /tmp/sapmm/

sudo cp install_sapsd_project.rb sapsd_issues.csv /tmp/sapsd/
```

Allow the Redmine user to read the working files:

```bash
sudo chmod -R a+rX /tmp/devops /tmp/cyber \
  /tmp/mikrotik /tmp/pg /tmp/sapbasis \
  /tmp/sapfico /tmp/sapmm /tmp/sapsd
```

**Important:** Each Ruby script must be able to locate its matching CSV dataset. If a script expects a specific filename or directory, adjust the copy operation or the script accordingly.

## 3. DevOps & Platform Engineering

Installer: `install_devops_project.rb`

Dataset: `redmine_issues.csv`

### Create the project with students and an instructor

```bash
runuser -l redmine -s /bin/bash -c "cd /opt/redmine && STUDENTS=alice,bob INSTRUCTORS=admin bundle exec rails runner -e production /tmp/devops/install_devops_project.rb"
```

### Assign a different set of students

```bash
runuser -l redmine -s /bin/bash -c "cd /opt/redmine && STUDENTS=student1,student2 INSTRUCTORS=admin bundle exec rails runner -e production /tmp/devops/install_devops_project.rb"
```

### Run in template mode

```bash
runuser -l redmine -s /bin/bash -c "cd /opt/redmine && TEMPLATE=1 bundle exec rails runner -e production /tmp/devops/install_devops_project.rb"
```

## 4. Cybersecurity & Security Operations

Installer: `install_cyber_project.rb`

Dataset: `cyber_issues.csv`

### Create the project with students and an instructor

```bash
runuser -l redmine -s /bin/bash -c "cd /opt/redmine && STUDENTS=student1,student2 INSTRUCTORS=admin bundle exec rails runner -e production /tmp/cyber/install_cyber_project.rb"
```

### Assign a specific student

```bash
runuser -l redmine -s /bin/bash -c "cd /opt/redmine && STUDENTS=ravi,priya INSTRUCTORS=admin bundle exec rails runner -e production /tmp/cyber/install_cyber_project.rb"
```

### Run in template mode

```bash
runuser -l redmine -s /bin/bash -c "cd /opt/redmine && TEMPLATE=1 bundle exec rails runner -e production /tmp/cyber/install_cyber_project.rb"
```

## 5. MikroTik Network Engineering

Installer: `install_mikrotik_project.rb`

Dataset: `mikrotik_issues.csv`

### Run in template mode

```bash
runuser -l redmine -s /bin/bash -c "cd /opt/redmine && TEMPLATE=1 INSTRUCTORS=admin bundle exec rails runner -e production /tmp/mikrotik/install_mikrotik_project.rb"
```

The project is intended for organizing network engineering exercises and tracking training issues in Redmine.

## 6. PostgreSQL Database Engineering

Installer: `install_postgresql_project.rb`

Dataset: `postgresql_issues.csv`

The repository currently uses filenames with `(1)` suffixes. The preparation commands above copy them into `/tmp/pg/` using the simpler names expected by the commands below.

### Install the PostgreSQL training project

```bash
runuser -l redmine -s /bin/bash -c "cd /opt/redmine && TEMPLATE=1 INSTRUCTORS=admin bundle exec rails runner -e production /tmp/pg/install_postgresql_project.rb"
```

### Install and assign a student

```bash
runuser -l redmine -s /bin/bash -c "cd /opt/redmine && STUDENTS=santhi TEMPLATE=1 INSTRUCTORS=admin bundle exec rails runner -e production /tmp/pg/install_postgresql_project.rb"
```

### Replace an existing project

**Destructive operation — use caution.**

The following is an example of a project-deletion workflow. Do not run it until you have confirmed the project identifier and reviewed the effects of the operation.

```bash
runuser -l redmine -s /bin/bash -c "cd /opt/redmine && bundle exec rails runner -e production 'p = Project.find_by(identifier: \"postgresql-database-engineering-development\"); if p; p.destroy!; puts \"Project deleted\"; else; puts \"Project not found\"; end'"
```

Project deletion can remove associated training data. Back up the database and confirm the target before using this operation.

After deletion, rerun the installation command to recreate the project.

## 7. SAP BASIS Administration

Installer: `install_sapbasis_project.rb`

Dataset: `sapbasis_issues.csv`

### Create the training project

```bash
runuser -l redmine -s /bin/bash -c "cd /opt/redmine && TEMPLATE=1 INSTRUCTORS=admin bundle exec rails runner -e production /tmp/sapbasis/install_sapbasis_project.rb"
```

### Assign students and instructor

```bash
runuser -l redmine -s /bin/bash -c "cd /opt/redmine && STUDENTS=student1,student2 INSTRUCTORS=admin bundle exec rails runner -e production /tmp/sapbasis/install_sapbasis_project.rb"
```

### Assign a specific student

```bash
runuser -l redmine -s /bin/bash -c "cd /opt/redmine && STUDENTS=santhi bundle exec rails runner -e production /tmp/sapbasis/install_sapbasis_project.rb"
```

## 8. SAP FICO

Installer: `install_sapfico_project.rb`

Dataset: `sapfico_issues.csv`

### Create the training project

```bash
runuser -l redmine -s /bin/bash -c "cd /opt/redmine && TEMPLATE=1 INSTRUCTORS=admin bundle exec rails runner -e production /tmp/sapfico/install_sapfico_project.rb"
```

### Assign the student `santhi`

```bash
runuser -l redmine -s /bin/bash -c "cd /opt/redmine && STUDENTS=santhi bundle exec rails runner -e production /tmp/sapfico/install_sapfico_project.rb"
```

### Assign multiple students and an instructor

```bash
runuser -l redmine -s /bin/bash -c "cd /opt/redmine && STUDENTS=student1,student2 INSTRUCTORS=admin bundle exec rails runner -e production /tmp/sapfico/install_sapfico_project.rb"
```

## 9. SAP Materials Management (MM)

Installer: `install_sapmm_project.rb`

Dataset: `sapmm_issues.csv`

### Create the training project

```bash
runuser -l redmine -s /bin/bash -c "cd /opt/redmine && TEMPLATE=1 INSTRUCTORS=admin bundle exec rails runner -e production /tmp/sapmm/install_sapmm_project.rb"
```

### Assign a specific student

```bash
runuser -l redmine -s /bin/bash -c "cd /opt/redmine && STUDENTS=santhi bundle exec rails runner -e production /tmp/sapmm/install_sapmm_project.rb"
```

### Assign multiple students and an instructor

```bash
runuser -l redmine -s /bin/bash -c "cd /opt/redmine && STUDENTS=student1,student2 INSTRUCTORS=admin bundle exec rails runner -e production /tmp/sapmm/install_sapmm_project.rb"
```

## 10. SAP Sales and Distribution (SD)

Installer: `install_sapsd_project.rb`

Dataset: `sapsd_issues.csv`

### Create the training project

```bash
runuser -l redmine -s /bin/bash -c "cd /opt/redmine && TEMPLATE=1 INSTRUCTORS=admin bundle exec rails runner -e production /tmp/sapsd/install_sapsd_project.rb"
```

### Assign a specific student

```bash
runuser -l redmine -s /bin/bash -c "cd /opt/redmine && STUDENTS=santhi bundle exec rails runner -e production /tmp/sapsd/install_sapsd_project.rb"
```

### Assign multiple students and an instructor

```bash
runuser -l redmine -s /bin/bash -c "cd /opt/redmine && STUDENTS=student1,student2 INSTRUCTORS=admin bundle exec rails runner -e production /tmp/sapsd/install_sapsd_project.rb"
```

## Environment Variables

The commands use environment variables to configure the project provisioning process.

| Variable | Example | Intended use |
|---|---|---|
| `STUDENTS` | `santhi` | Specify student login names |
| `STUDENTS` | `alice,bob` | Specify multiple students |
| `INSTRUCTORS` | `admin` | Specify instructor login names |
| `TEMPLATE` | `1` | Enable template-related behavior if supported |

Environment variables are passed to the Ruby process through the shell. Their actual effects depend on how each installer script reads them. Review the source code before assuming every script supports every variable.

## Verify a Project Installation

After running an installer:

1. Open the Redmine web interface.
2. Locate the relevant training project.
3. Confirm that the expected issues have been created or updated.
4. Verify student assignments and instructor permissions.
5. Confirm that issue descriptions, statuses, and trackers appear correctly.
6. Review the production log if anything fails.

```bash
sudo tail -n 100 /opt/redmine/log/production.log
```

Confirm the application environment can start:

```bash
runuser -l redmine -s /bin/bash -c "cd /opt/redmine && bundle exec rails runner -e production 'puts Rails.env'"
```

The expected environment is:

```text
production
```

## Troubleshooting

### Installer script not found

Check the working directory:

```bash
ls -l /tmp/devops/
ls -l /tmp/cyber/
ls -l /tmp/mikrotik/
ls -l /tmp/pg/
ls -l /tmp/sapbasis/
ls -l /tmp/sapfico/
ls -l /tmp/sapmm/
ls -l /tmp/sapsd/
```

### CSV dataset not found

Confirm that the correct dataset was copied into the expected location. Check the installer source code to determine whether it expects the CSV in `/tmp/PROJECT/`, the current directory, or another location.

### Student or instructor not found

Ensure the login names exist in Redmine. A Linux username is not necessarily the same as a Redmine login.

### Rails or Bundler error

Run commands as the Redmine application owner and from the correct installation directory. Verify that the installed gems match the Redmine version.

### Project already exists

Review the installer logic to determine whether it creates a new project, updates an existing project, or deletes existing records. Back up the database before any operation that could modify or remove project data.

## Recommended Operating Procedure

1. Back up the Redmine database.
2. Confirm the application path and owner.
3. Prepare the relevant Ruby installer and CSV file.
4. Review the script and supported environment variables.
5. Execute the command in a staging environment.
6. Verify the project and assignments in Redmine.
7. Repeat for the other training domains.
8. Keep a record of successful installations and any domain-specific changes.

## Official Documentation

- [Redmine Installation Guide](https://www.redmine.org/projects/redmine/wiki/RedmineInstall)
- [Redmine REST API](https://www.redmine.org/projects/redmine/wiki/Rest_api)
- [Redmine Projects API](https://www.redmine.org/projects/redmine/wiki/rest_projects)

## Disclaimer

This repository provides training automation scripts and issue datasets. Review the scripts before execution and test them with your installed Redmine version. Back up the database before running operations that create, update, or delete projects and issues.

## License

Add a `LICENSE` file to specify the terms under which this repository may be used, modified, and redistributed.
