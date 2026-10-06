# SAP BASIS Complete Training Basic to Expert - one-shot Redmine installer
#
# Put this file and sapbasis_issues.csv in the same folder. Run on the Redmine server,
# from the Redmine root directory, as the Redmine OS user:
#
#   STUDENTS=alice,bob INSTRUCTORS=admin \
#     bundle exec rails runner -e production /path/to/install_sapbasis_project.rb
#
# Environment variables (all optional):
#   CSV            path to sapbasis_issues.csv (default: same folder as this script)
#   STUDENTS       comma-separated Redmine logins; each gets a full personal copy of the course
#   INSTRUCTORS    comma-separated Redmine logins added with the Instructor role
#   TEMPLATE=1     also create one unassigned template copy (status New)
#
# Safe to re-run: existing objects are kept, students who already have the issues are skipped.

require 'csv'
require 'json'

$stdout.sync = true
$tag = 'course'
def say(msg)
  puts "[#{$tag}] #{msg}"
end

def halt(msg)
  puts "[#{$tag}] ERROR: #{msg}"
  exit 1
end

script_dir = File.dirname(File.expand_path(__FILE__)) rescue Dir.pwd
course_dir = ENV['COURSE_DIR'].to_s.strip
course_dir = script_dir if course_dir.empty?
csv_path   = ENV['CSV'].to_s.strip
csv_path   = File.join(course_dir, 'sapbasis_issues.csv') if csv_path.empty?
halt("not found: #{csv_path} (set CSV=/path/to/sapbasis_issues.csv)") unless File.file?(csv_path)

# The project definition (fields, queries, wiki pages) is embedded at the end of this file.
embedded = File.read(File.expand_path(__FILE__), :encoding => 'utf-8').split("\n__END__\n", 2)[1]
halt('embedded project definition missing from this script') if embedded.to_s.strip.empty?
course = JSON.parse(embedded)
$tag   = course['tag'].to_s.empty? ? 'course' : course['tag']
rows   = CSV.read(csv_path, :headers => true, :encoding => 'bom|utf-8').map(&:to_h)
halt('sapbasis_issues.csv is empty') if rows.empty?
%w(Unique\ ID Curriculum\ ID Tracker Priority Subject Description Category Target\ version Parent
   Blocked\ by Estimated\ hours).each do |col|
  halt("CSV column missing: #{col}") unless rows.first.key?(col)
end

student_logins    = ENV['STUDENTS'].to_s.split(',').map(&:strip).reject(&:empty?).uniq
instructor_logins = ENV['INSTRUCTORS'].to_s.split(',').map(&:strip).reject(&:empty?).uniq
want_template     = ENV['TEMPLATE'].to_s == '1'

admin = User.active.where(:admin => true).order(:id).first
halt('no active administrator account found') unless admin
User.current = admin
say "#{course['project']['name']}: #{rows.size} rows; running as #{admin.login} on Redmine #{Redmine::VERSION}"

# No e-mail and no background mail jobs from this run. These overrides live only in this
# process; the running Redmine application is not affected.
ActionMailer::Base.perform_deliveries = false
Issue.class_eval do
  def notify?
    false
  end
end
Journal.class_eval do
  def notify?
    false
  end
end

# ---------------------------------------------------------------- statuses
STATUS_DEFS = [
  ['New',         false, 0],
  ['Assigned',    false, 0],
  ['In Progress', false, 20],
  ['Blocked',     false, 20],
  ['Testing',     false, 60],
  ['Review',      false, 80],
  ['Reopened',    false, 20],
  ['Completed',   true,  100],
  ['Rejected',    true,  nil]
]
st = {}
STATUS_DEFS.each do |name, closed, ratio|
  s = IssueStatus.where(:name => name).first
  if s.nil?
    s = IssueStatus.new(:name => name)
    s.is_closed = closed
    s.default_done_ratio = ratio
    s.save!
    say "status created: #{name}"
  elsif s.default_done_ratio.nil? && !ratio.nil?
    s.update_column(:default_done_ratio, ratio)
  end
  st[name] = s
end

# ---------------------------------------------------------------- trackers
tr = {}
container_trackers = []
work_trackers      = []
course['trackers'].each do |d|
  t = Tracker.where(:name => d['name']).first
  if t.nil?
    t = Tracker.new(:name => d['name'])
    t.default_status = st['New']
    t.core_fields = Tracker::CORE_FIELDS
    t.save!
    say "tracker created: #{d['name']}"
  end
  tr[d['name']] = t
  (d['kind'] == 'container' ? container_trackers : work_trackers) << t
end
all_t = container_trackers + work_trackers

# ---------------------------------------------------------------- enumerations
(course['activities'] || []).each do |name|
  next if TimeEntryActivity.where(:name => name, :project_id => nil).exists?
  TimeEntryActivity.create!(:name => name, :active => true)
  say "time activity created: #{name}"
end
default_priority = IssuePriority.default || IssuePriority.active.order(:position).first
default_priority = IssuePriority.create!(:name => 'Normal', :is_default => true) if default_priority.nil?
prio = {}
%w(Low Normal High Urgent).each { |n| prio[n] = IssuePriority.where(:name => n).first || default_priority }

# ---------------------------------------------------------------- custom fields
def split_multi(value)
  value.to_s.split(';').map(&:strip).reject(&:empty?)
end

cf = {}
cf_columns = []
course['custom_fields'].each do |d|
  name     = d['name']
  format   = d['format']
  multiple = d['multiple'] == true
  col      = d['csv']
  values   = d['values']
  if format == 'list' && values.nil? && col
    values = rows.map { |r| multiple ? split_multi(r[col]) : [r[col].to_s.strip] }.flatten.reject(&:empty?).uniq
    values = values.sort if d['sort']
  end
  trackers =
    case d['trackers']
    when 'all'  then all_t
    when 'work' then work_trackers
    else Array(d['trackers']).map { |n| tr[n] }.compact
    end
  f = IssueCustomField.where(:name => name).first
  if f.nil?
    f = IssueCustomField.new(:name => name)
    f.field_format = format
    f.possible_values = values if format == 'list'
    f.multiple    = multiple if format == 'list'
    f.is_filter   = true
    f.searchable  = d['searchable'] == true
    f.is_for_all  = false
    f.is_required = false
    f.editable    = true
    f.visible     = true
    f.trackers    = trackers
    f.save!
    say "custom field created: #{name}"
  else
    if format == 'list' && f.field_format == 'list' && values
      missing = values - f.possible_values.to_a
      unless missing.empty?
        f.possible_values = f.possible_values.to_a + missing
        f.save!
      end
    end
    add = trackers - f.trackers.to_a
    f.trackers << add unless add.empty?
  end
  cf[name] = f
  cf_columns << [name, col, multiple] if col
end

# ---------------------------------------------------------------- roles
known_perms = Redmine::AccessControl.permissions.map(&:name)
INSTRUCTOR_PERMS = [
  :edit_project, :select_project_modules, :view_members, :manage_members, :manage_versions,
  :manage_categories, :manage_public_queries, :save_queries,
  :view_issues, :add_issues, :edit_issues, :copy_issues, :manage_issue_relations, :manage_subtasks,
  :add_issue_notes, :edit_issue_notes, :edit_own_issue_notes, :view_private_notes, :set_notes_private,
  :delete_issues, :view_issue_watchers, :add_issue_watchers, :delete_issue_watchers, :import_issues,
  :view_time_entries, :log_time, :edit_time_entries, :edit_own_time_entries, :manage_project_activities,
  :view_documents, :add_documents, :edit_documents, :delete_documents, :view_files, :manage_files,
  :view_wiki_pages, :view_wiki_edits, :export_wiki_pages, :edit_wiki_pages, :rename_wiki_pages,
  :delete_wiki_pages, :delete_wiki_pages_attachments, :protect_wiki_pages, :manage_wiki,
  :view_calendar, :view_gantt
]
REVIEWER_PERMS = [
  :view_members, :save_queries, :view_issues, :edit_issues, :add_issue_notes, :edit_own_issue_notes,
  :view_private_notes, :view_issue_watchers, :view_time_entries, :view_documents, :view_files,
  :view_wiki_pages, :view_wiki_edits, :view_calendar, :view_gantt
]
STUDENT_PERMS = [
  :save_queries, :view_issues, :edit_issues, :add_issue_notes, :edit_own_issue_notes,
  :view_issue_watchers, :add_issue_watchers, :view_time_entries, :log_time, :edit_own_time_entries,
  :view_documents, :view_files, :view_wiki_pages, :view_calendar, :view_gantt
]
OBSERVER_PERMS = [:view_issues, :view_time_entries, :view_wiki_pages, :view_calendar, :view_gantt]
ROLE_DEFS = [
  ['Instructor', INSTRUCTOR_PERMS, 'all', 'all', false],
  ['Reviewer',   REVIEWER_PERMS,   'all', 'all', false],
  ['Student',    STUDENT_PERMS,    'own', 'own', true],
  ['Observer',   OBSERVER_PERMS,   'all', 'all', false]
]
role = {}
ROLE_DEFS.each do |name, perms, issues_vis, time_vis, assignable|
  r = Role.where(:name => name).first
  if r.nil?
    r = Role.new(:name => name)
    r.permissions = perms & known_perms
    r.issues_visibility = issues_vis
    r.time_entries_visibility = time_vis if r.respond_to?(:time_entries_visibility=)
    r.assignable = assignable
    r.save!
    say "role created: #{name}"
  end
  role[name] = r
end

# ---------------------------------------------------------------- workflow
STUDENT_MOVES = [
  ['Assigned', 'In Progress'], ['In Progress', 'Blocked'], ['Blocked', 'In Progress'],
  ['In Progress', 'Testing'], ['Testing', 'In Progress'], ['Testing', 'Review'],
  ['Reopened', 'In Progress']
]
all_status_names = STATUS_DEFS.map(&:first)
full_matrix      = all_status_names.product(all_status_names).reject { |a, b| a == b }
container_names  = ['New', 'Assigned', 'In Progress', 'Completed']
container_matrix = container_names.product(container_names).reject { |a, b| a == b }

def set_transitions(tracker, a_role, pairs, st)
  WorkflowTransition.where(:tracker_id => tracker.id, :role_id => a_role.id).delete_all
  pairs.each do |from, to|
    WorkflowTransition.create!(:tracker_id => tracker.id, :role_id => a_role.id,
                               :old_status_id => st[from].id, :new_status_id => st[to].id)
  end
end

work_trackers.each do |t|
  set_transitions(t, role['Student'],    STUDENT_MOVES, st)
  set_transitions(t, role['Instructor'], full_matrix,   st)
  set_transitions(t, role['Reviewer'],   full_matrix,   st)
end
container_trackers.each do |t|
  set_transitions(t, role['Student'],    [['Assigned', 'In Progress']], st)
  set_transitions(t, role['Instructor'], container_matrix, st)
  set_transitions(t, role['Reviewer'],   container_matrix, st)
end

# custom fields a student fills in (incident analysis); all others are read-only for students
student_editable = course['custom_fields'].select { |d| d['student_editable'] }.map { |d| d['name'] }
readonly_core = %w(tracker_id subject description priority_id category_id fixed_version_id
                   assigned_to_id parent_issue_id estimated_hours start_date due_date)
all_t.each do |t|
  WorkflowPermission.where(:tracker_id => t.id, :role_id => role['Student'].id).delete_all
  fields = readonly_core + t.custom_fields.reject { |f| student_editable.include?(f.name) }.map { |f| f.id.to_s }
  st.values.each do |status|
    fields.each do |field|
      begin
        WorkflowPermission.create!(:tracker_id => t.id, :role_id => role['Student'].id,
                                   :old_status_id => status.id, :field_name => field, :rule => 'readonly')
      rescue => e
        say "warning: read-only rule #{t.name}/#{field} skipped (#{e.message})"
      end
    end
  end
end
say 'workflow and field permissions set'

# ---------------------------------------------------------------- project
pdef    = course['project']
project = Project.where(:identifier => pdef['identifier']).first
if project.nil?
  project = Project.new(:name => pdef['name'])
  project.identifier  = pdef['identifier']
  project.is_public   = false
  project.description = pdef['description']
  project.enabled_module_names = %w(issue_tracking time_tracking wiki files documents calendar gantt)
  project.save!
  project.trackers = all_t
  say "project created: #{project.name} (#{project.identifier})"
else
  say "project exists: #{project.name} (#{project.identifier})"
end
project.trackers = (project.trackers.to_a | all_t)
project.issue_custom_fields = (project.issue_custom_fields.to_a | cf.values)
project.save!
project.reload

ver = {}
(course['versions'] || []).each do |name|
  v = project.versions.where(:name => name).first
  if v.nil?
    v = Version.new(:name => name)
    v.project = project
    v.sharing = 'none'
    v.status  = 'open'
    v.save!
  end
  ver[name] = v
end
cat = {}
rows.map { |r| r['Category'].to_s.strip }.reject(&:empty?).uniq.sort.each do |name|
  c = project.issue_categories.where(:name => name).first
  if c.nil?
    c = IssueCategory.new(:name => name)
    c.project = project
    c.save!
  end
  cat[name] = c
end
say "versions: #{ver.size}, categories: #{cat.size}"

# ---------------------------------------------------------------- members
def add_member(project, user, a_role)
  m = Member.where(:project_id => project.id, :user_id => user.id).first
  if m.nil?
    m = Member.new
    m.project   = project
    m.principal = user
    m.role_ids  = [a_role.id]
    m.save!
  elsif !m.role_ids.include?(a_role.id)
    m.role_ids = m.role_ids + [a_role.id]
    m.save!
  end
end

def find_user(login)
  User.active.where('LOWER(login) = ?', login.downcase).first
end

instructor_logins.each do |login|
  u = find_user(login)
  if u.nil?
    say "warning: instructor '#{login}' not found or not active, skipped"
  else
    add_member(project, u, role['Instructor'])
    say "instructor added: #{u.login}"
  end
end
students = []
student_logins.each do |login|
  u = find_user(login)
  if u.nil?
    say "warning: student '#{login}' not found or not active, skipped (create the user, then re-run)"
  else
    add_member(project, u, role['Student'])
    students << u
  end
end

# ---------------------------------------------------------------- wiki
textile = Setting.text_formatting.to_s == 'textile'
def to_textile(text)
  text.to_s.lines.map do |line|
    l = line.chomp
    l = l.sub(/\A(#+) (.*)\z/) { "h#{$1.length}. #{$2}\n" }
    l = l.sub(/\A- \[ \] /, '* ')
    l = l.sub(/\A- /, '* ')
    l = l.gsub(/\*\*(.+?)\*\*/) { "*#{$1}*" }
    l
  end.join("\n")
end

wiki_made = 0
begin
  wiki = project.wiki || Wiki.create!(:project => project, :start_page => 'Wiki')
  (course['wiki'] || []).each do |pg|
    begin
      next if wiki.pages.where(:title => pg['title']).exists?
      page = WikiPage.new(:wiki => wiki, :title => pg['title'])
      if pg['parent']
        parent = wiki.pages.where(:title => pg['parent']).first
        page.parent_id = parent.id if parent
      end
      text = textile ? to_textile(pg['text']) : pg['text']
      page.content = WikiContent.new(:page => page, :text => text, :author => admin)
      page.save!
      wiki_made += 1
    rescue => e
      say "warning: wiki page '#{pg['title']}' skipped (#{e.message})"
    end
  end
rescue => e
  say "warning: wiki skipped (#{e.message})"
end
say "wiki pages created: #{wiki_made}"

# ---------------------------------------------------------------- issues
cid_field = cf['Curriculum ID'] || halt('course.json must define the custom field "Curriculum ID"')

def split_refs(value)
  value.to_s.split(',').map(&:strip).reject(&:empty?)
end

install_copy = lambda do |owner|
  label = owner ? owner.login : 'template (unassigned)'
  scope = Issue.where(:project_id => project.id)
  scope = owner ? scope.where(:assigned_to_id => owner.id) : scope.where(:assigned_to_id => nil)
  existing = {}
  scope.joins(:custom_values)
       .where(:custom_values => { :custom_field_id => cid_field.id })
       .select("#{Issue.table_name}.id, #{CustomValue.table_name}.value AS curriculum_id")
       .each { |i| existing[i.curriculum_id] = i.id }
  if existing.size >= rows.size
    say "#{label}: already has #{existing.size} issues, skipped"
    next
  end

  created = 0
  Issue.transaction do
    by_uid  = {}
    new_ids = []
    fresh   = {}
    rows.each do |r|
      uid = r['Unique ID']
      if existing[r['Curriculum ID']]
        by_uid[uid] = Issue.find(existing[r['Curriculum ID']])
        next
      end
      i = Issue.new
      i.project  = project
      i.tracker  = tr[r['Tracker']] || halt("unknown tracker in CSV: #{r['Tracker']}")
      i.author   = admin
      i.status   = st['New']
      i.priority = prio[r['Priority']] || default_priority
      i.subject  = r['Subject']
      i.description = textile ? to_textile(r['Description']) : r['Description']
      i.category      = cat[r['Category'].to_s.strip]
      i.fixed_version = ver[r['Target version'].to_s.strip]
      hours = r['Estimated hours'].to_s.strip
      i.estimated_hours = hours.to_f unless hours.empty?
      parent_uid = r['Parent'].to_s.strip
      unless parent_uid.empty?
        parent = by_uid[parent_uid] || halt("parent #{parent_uid} not found for #{uid}")
        i.parent_issue_id = parent.id
      end
      values = {}
      cf_columns.each do |name, col, multiple|
        raw = r[col].to_s.strip
        next if raw.empty?
        values[cf[name].id.to_s] = multiple ? split_multi(raw) : raw
      end
      i.custom_field_values = values
      unless i.save
        halt("#{label}: #{uid} not saved: #{i.errors.full_messages.join('; ')}")
      end
      by_uid[uid] = i
      fresh[uid]  = i
      new_ids << i.id
      created += 1
      say "#{label}: #{created} issues created" if (created % 100).zero?
    end

    relations = 0
    rows.each do |r|
      blocked = fresh[r['Unique ID']]
      next if blocked.nil?
      split_refs(r['Blocked by']).each do |ref|
        blocker = by_uid[ref] || halt("blocker #{ref} not found for #{r['Unique ID']}")
        rel = IssueRelation.new
        rel.issue_from    = blocker
        rel.issue_to      = blocked
        rel.relation_type = 'blocks'
        unless rel.save
          halt("#{label}: relation #{ref} blocks #{r['Unique ID']} not saved: #{rel.errors.full_messages.join('; ')}")
        end
        relations += 1
      end
    end

    if owner
      Issue.where(:id => new_ids).update_all(:assigned_to_id => owner.id, :status_id => st['Assigned'].id)
    end
    say "#{label}: done, #{created} issues and #{relations} blocked-by relations created"
  end
end

install_copy.call(nil) if want_template
students.each { |u| install_copy.call(u) }
if students.empty? && !want_template
  say 'no issues created: pass STUDENTS=login1,login2 (or TEMPLATE=1 for an unassigned copy)'
end

# ---------------------------------------------------------------- saved queries
resolve = lambda do |token|
  t = token.to_s
  if t.start_with?('status:')
    names = t.sub('status:', '').split('+')
    names.map { |n| (st[n] || halt("query: unknown status #{n}")).id.to_s }
  elsif t.start_with?('tracker:')
    names = t.sub('tracker:', '').split('+')
    names.map { |n| (tr[n] || halt("query: unknown tracker #{n}")).id.to_s }
  elsif t.start_with?('category:')
    [(cat[t.sub('category:', '')] || halt("query: unknown category #{t}")).id.to_s]
  elsif t.start_with?('cf:')
    f = cf[t.sub('cf:', '')] || halt("query: unknown custom field #{t}")
    ["cf_#{f.id}"]
  else
    [t]
  end
end
field_of = lambda { |token| resolve.call(token).first }

queries_made = 0
(course['queries'] || []).each do |d|
  begin
    next if IssueQuery.where(:project_id => project.id, :name => d['name']).exists?
    q = IssueQuery.new(:name => d['name'])
    q.project = project
    q.user    = admin
    filters = {}
    d['filters'].each do |field, op, vals|
      filters[field_of.call(field)] = { :operator => op, :values => (vals || ['']).map { |v| resolve.call(v) }.flatten }
    end
    q.filters         = filters
    q.column_names    = d['columns'].map { |c| field_of.call(c).to_sym }
    q.group_by        = d['group_by'] ? field_of.call(d['group_by']) : nil
    q.totalable_names = (d['totals'] || []).map { |c| field_of.call(c).to_sym }
    q.sort_criteria   = d['sort'] || [['id', 'asc']]
    if d['roles'] == 'staff'
      q.visibility = Query::VISIBILITY_ROLES
      q.roles      = [role['Instructor'], role['Reviewer']]
    else
      q.visibility = Query::VISIBILITY_PUBLIC
    end
    q.save!
    queries_made += 1
  rescue => e
    say "warning: saved query '#{d['name']}' skipped (#{e.message})"
  end
end
say "saved queries created: #{queries_made}"

# ---------------------------------------------------------------- summary
total = Issue.where(:project_id => project.id).count
say '-' * 60
say "Project:  /projects/#{project.identifier}"
say "Issues:   #{total} in project (#{rows.size} per student)"
say "Students: #{students.map(&:login).join(', ')}" unless students.empty?
say 'Finished.'

__END__
{
 "tag": "sapbasis",
 "project": {
  "name": "SAP BASIS — Complete Training Basic to Expert",
  "identifier": "sap-basis-complete-training",
  "description": "SAP Basis programme from IT and Linux fundamentals to SAP technical consultant: Linux, networking, databases, SAP architecture, installation, core Basis administration, transports, monitoring, performance, SAP HANA administration, backup and recovery, HA/DR, S/4HANA and Fiori, security and certificates, system copy and refresh, upgrade and migration, cloud, automation, observability, production support and troubleshooting, in 59 modules ending in an enterprise landscape capstone. Every topic follows Concept -> Architecture -> Configuration -> Administration -> Monitoring -> Troubleshooting -> Recovery -> Automation -> Project -> Production Support. One shared project; every student has a personal copy of each issue."
 },
 "trackers": [
  {
   "name": "Epic",
   "kind": "container"
  },
  {
   "name": "Module",
   "kind": "container"
  },
  {
   "name": "Theory",
   "kind": "work"
  },
  {
   "name": "Configuration",
   "kind": "work"
  },
  {
   "name": "Installation Lab",
   "kind": "work"
  },
  {
   "name": "Administration Lab",
   "kind": "work"
  },
  {
   "name": "HANA Lab",
   "kind": "work"
  },
  {
   "name": "Troubleshooting Incident",
   "kind": "work"
  },
  {
   "name": "Assignment",
   "kind": "work"
  },
  {
   "name": "Assessment",
   "kind": "work"
  },
  {
   "name": "Production Incident",
   "kind": "work"
  },
  {
   "name": "Project",
   "kind": "work"
  },
  {
   "name": "Documentation",
   "kind": "work"
  },
  {
   "name": "Interview Question",
   "kind": "work"
  },
  {
   "name": "RCA",
   "kind": "work"
  },
  {
   "name": "Change Request",
   "kind": "work"
  },
  {
   "name": "Capstone Task",
   "kind": "work"
  },
  {
   "name": "Review",
   "kind": "work"
  }
 ],
 "activities": [
  "Learning",
  "Lab",
  "Installation",
  "Configuration",
  "Troubleshooting",
  "Documentation",
  "Testing",
  "Review",
  "Operations",
  "Automation",
  "Interview Preparation"
 ],
 "versions": [
  "V01 - IT Foundation",
  "V02 - Linux & Networking",
  "V03 - SAP Foundation",
  "V04 - Core Basis",
  "V05 - Monitoring",
  "V06 - Transport",
  "V07 - Security",
  "V08 - HANA Administration",
  "V09 - S/4HANA",
  "V10 - HA/DR",
  "V11 - Backup/Recovery",
  "V12 - Upgrade/Migration",
  "V13 - Cloud",
  "V14 - Automation",
  "V15 - Production Support",
  "V16 - Expert Architecture",
  "V17 - Final Capstone"
 ],
 "custom_fields": [
  {
   "name": "Curriculum ID",
   "format": "string",
   "trackers": "all",
   "searchable": true,
   "csv": "Curriculum ID"
  },
  {
   "name": "Level",
   "format": "list",
   "trackers": "all",
   "csv": "Level",
   "values": [
    "Level 1 - IT, SAP, Linux and Basis Foundation",
    "Level 2 - Core SAP Basis Administration",
    "Level 3 - Advanced SAP Basis, HANA and S/4HANA",
    "Level 4 - Enterprise SAP Technical Architecture and Expert Operations"
   ]
  },
  {
   "name": "Module",
   "format": "list",
   "trackers": "all",
   "csv": "Module",
   "sort": true
  },
  {
   "name": "SAP Component",
   "format": "list",
   "trackers": "all",
   "csv": "SAP Component"
  },
  {
   "name": "SAP Version",
   "format": "string",
   "trackers": "all",
   "csv": "SAP Version"
  },
  {
   "name": "ECC/S4HANA",
   "format": "list",
   "trackers": "all",
   "csv": "ECC/S4HANA",
   "values": [
    "Not system specific",
    "ECC and S/4HANA",
    "ECC and S/4HANA (changed in S/4HANA)",
    "HANA and S/4HANA"
   ]
  },
  {
   "name": "HANA Version",
   "format": "string",
   "trackers": "all",
   "csv": "HANA Version"
  },
  {
   "name": "Linux Distribution",
   "format": "string",
   "trackers": "all",
   "csv": "Linux Distribution"
  },
  {
   "name": "Difficulty",
   "format": "list",
   "trackers": "work",
   "csv": "Difficulty",
   "sort": true
  },
  {
   "name": "Lab Required",
   "format": "bool",
   "trackers": "work",
   "csv": "Lab Required"
  },
  {
   "name": "Environment",
   "format": "list",
   "trackers": "all",
   "csv": "Environment",
   "values": [
    "Workbook or design exercise",
    "Linux lab server",
    "SAP ABAP lab system",
    "SAP HANA lab system",
    "HA/DR lab cluster",
    "Cloud account or design exercise",
    "Monitoring lab stack"
   ]
  },
  {
   "name": "DEV/QAS/PRD",
   "format": "list",
   "trackers": "all",
   "csv": "DEV/QAS/PRD",
   "values": [
    "Lab (sandbox)",
    "DEV",
    "QAS",
    "PRD (simulated)",
    "DEV > QAS > PRD"
   ]
  },
  {
   "name": "Incident Severity",
   "format": "list",
   "trackers": [
    "Troubleshooting Incident",
    "Production Incident",
    "RCA",
    "Capstone Task"
   ],
   "values": [
    "P1 - Critical",
    "P2 - High",
    "P3 - Medium",
    "P4 - Low"
   ],
   "csv": "Incident Severity"
  },
  {
   "name": "Business Impact",
   "format": "text",
   "trackers": [
    "Troubleshooting Incident",
    "Production Incident",
    "RCA",
    "Capstone Task"
   ],
   "student_editable": true
  },
  {
   "name": "Root Cause",
   "format": "text",
   "trackers": [
    "Troubleshooting Incident",
    "Production Incident",
    "RCA",
    "Capstone Task"
   ],
   "student_editable": true
  },
  {
   "name": "Resolution",
   "format": "text",
   "trackers": [
    "Troubleshooting Incident",
    "Production Incident",
    "RCA",
    "Capstone Task"
   ],
   "student_editable": true
  },
  {
   "name": "Configuration Required",
   "format": "bool",
   "trackers": "work",
   "csv": "Configuration Required"
  },
  {
   "name": "Integration",
   "format": "list",
   "trackers": "all",
   "csv": "Integration",
   "values": [
    "None",
    "Linux",
    "Network",
    "HANA"
   ]
  },
  {
   "name": "Assessment Score",
   "format": "int",
   "trackers": [
    "Assessment",
    "Project",
    "Capstone Task"
   ]
  },
  {
   "name": "Project",
   "format": "list",
   "trackers": "work",
   "csv": "Project Name"
  },
  {
   "name": "Deliverable",
   "format": "string",
   "trackers": "work",
   "csv": "Deliverable"
  },
  {
   "name": "Evidence",
   "format": "list",
   "trackers": "work",
   "csv": "Evidence"
  },
  {
   "name": "Interview Topic",
   "format": "list",
   "trackers": "all",
   "csv": "Interview Topic",
   "values": [
    "SAP Basis Beginner",
    "Linux",
    "Networking",
    "SAP Architecture",
    "Installation",
    "Kernel",
    "Work Process",
    "Job",
    "Transport",
    "Monitoring",
    "Performance",
    "HANA",
    "S/4HANA",
    "Security",
    "HA/DR",
    "Upgrade",
    "Migration",
    "Production Support",
    "Scenario-Based",
    "Architect-Level"
   ]
  },
  {
   "name": "Instructor Review",
   "format": "list",
   "trackers": "work",
   "values": [
    "Pending",
    "Approved",
    "Changes Requested"
   ],
   "csv": "Instructor Review"
  }
 ],
 "queries": [
  {
   "name": "My next tasks",
   "roles": "public",
   "filters": [
    [
     "assigned_to_id",
     "=",
     [
      "me"
     ]
    ],
    [
     "tracker_id",
     "!",
     [
      "tracker:Epic+Module"
     ]
    ],
    [
     "status_id",
     "=",
     [
      "status:Assigned+In Progress+Reopened"
     ]
    ]
   ],
   "columns": [
    "cf:Curriculum ID",
    "subject",
    "status",
    "cf:Difficulty",
    "estimated_hours"
   ],
   "group_by": "fixed_version",
   "totals": [
    "estimated_hours"
   ],
   "sort": [
    [
     "id",
     "asc"
    ]
   ]
  },
  {
   "name": "My blocked",
   "roles": "public",
   "filters": [
    [
     "assigned_to_id",
     "=",
     [
      "me"
     ]
    ],
    [
     "status_id",
     "=",
     [
      "status:Blocked"
     ]
    ]
   ],
   "columns": [
    "cf:Curriculum ID",
    "subject",
    "updated_on"
   ],
   "group_by": null,
   "totals": [],
   "sort": [
    [
     "id",
     "asc"
    ]
   ]
  },
  {
   "name": "My completed work",
   "roles": "public",
   "filters": [
    [
     "assigned_to_id",
     "=",
     [
      "me"
     ]
    ],
    [
     "tracker_id",
     "!",
     [
      "tracker:Epic+Module"
     ]
    ],
    [
     "status_id",
     "=",
     [
      "status:Completed"
     ]
    ]
   ],
   "columns": [
    "cf:Curriculum ID",
    "subject",
    "closed_on",
    "spent_hours"
   ],
   "group_by": "fixed_version",
   "totals": [
    "spent_hours"
   ],
   "sort": [
    [
     "id",
     "asc"
    ]
   ]
  },
  {
   "name": "My in review",
   "roles": "public",
   "filters": [
    [
     "assigned_to_id",
     "=",
     [
      "me"
     ]
    ],
    [
     "status_id",
     "=",
     [
      "status:Testing+Review"
     ]
    ]
   ],
   "columns": [
    "cf:Curriculum ID",
    "subject",
    "status",
    "cf:Instructor Review",
    "updated_on"
   ],
   "group_by": null,
   "totals": [],
   "sort": [
    [
     "id",
     "asc"
    ]
   ]
  },
  {
   "name": "Dashboard: overall completion",
   "roles": "public",
   "filters": [
    [
     "assigned_to_id",
     "=",
     [
      "me"
     ]
    ],
    [
     "status_id",
     "*",
     null
    ],
    [
     "tracker_id",
     "=",
     [
      "tracker:Epic"
     ]
    ]
   ],
   "columns": [
    "subject",
    "status",
    "done_ratio",
    "estimated_hours",
    "spent_hours"
   ],
   "group_by": null,
   "totals": [],
   "sort": [
    [
     "id",
     "asc"
    ]
   ]
  },
  {
   "name": "Dashboard: level completion",
   "roles": "public",
   "filters": [
    [
     "assigned_to_id",
     "=",
     [
      "me"
     ]
    ],
    [
     "tracker_id",
     "!",
     [
      "tracker:Epic+Module"
     ]
    ],
    [
     "status_id",
     "*",
     null
    ]
   ],
   "columns": [
    "cf:Curriculum ID",
    "subject",
    "status",
    "estimated_hours",
    "spent_hours"
   ],
   "group_by": "cf:Level",
   "totals": [
    "estimated_hours",
    "spent_hours"
   ],
   "sort": [
    [
     "id",
     "asc"
    ]
   ]
  },
  {
   "name": "Dashboard: module completion",
   "roles": "public",
   "filters": [
    [
     "assigned_to_id",
     "=",
     [
      "me"
     ]
    ],
    [
     "status_id",
     "*",
     null
    ],
    [
     "tracker_id",
     "=",
     [
      "tracker:Module"
     ]
    ]
   ],
   "columns": [
    "cf:Curriculum ID",
    "subject",
    "status",
    "done_ratio"
   ],
   "group_by": "fixed_version",
   "totals": [],
   "sort": [
    [
     "id",
     "asc"
    ]
   ]
  },
  {
   "name": "Dashboard: lab completion",
   "roles": "public",
   "filters": [
    [
     "assigned_to_id",
     "=",
     [
      "me"
     ]
    ],
    [
     "status_id",
     "*",
     null
    ],
    [
     "tracker_id",
     "=",
     [
      "tracker:Configuration+Installation Lab+Administration Lab+HANA Lab"
     ]
    ]
   ],
   "columns": [
    "cf:Curriculum ID",
    "subject",
    "status",
    "closed_on",
    "estimated_hours",
    "spent_hours"
   ],
   "group_by": "status",
   "totals": [
    "estimated_hours",
    "spent_hours"
   ],
   "sort": [
    [
     "id",
     "asc"
    ]
   ]
  },
  {
   "name": "Dashboard: HANA progress",
   "roles": "public",
   "filters": [
    [
     "assigned_to_id",
     "=",
     [
      "me"
     ]
    ],
    [
     "tracker_id",
     "!",
     [
      "tracker:Epic+Module"
     ]
    ],
    [
     "status_id",
     "*",
     null
    ],
    [
     "cf:Module",
     "=",
     [
      "30 HANA Architecture",
      "31 HANA Installation",
      "32 HANA Administration",
      "33 HANA Security",
      "34 HANA Backup",
      "35 HANA Recovery",
      "36 HANA HA",
      "37 HANA DR",
      "38 HANA Performance"
     ]
    ]
   ],
   "columns": [
    "cf:Curriculum ID",
    "subject",
    "status",
    "estimated_hours",
    "spent_hours"
   ],
   "group_by": "cf:Module",
   "totals": [
    "estimated_hours",
    "spent_hours"
   ],
   "sort": [
    [
     "id",
     "asc"
    ]
   ]
  },
  {
   "name": "Dashboard: S/4HANA progress",
   "roles": "public",
   "filters": [
    [
     "assigned_to_id",
     "=",
     [
      "me"
     ]
    ],
    [
     "tracker_id",
     "!",
     [
      "tracker:Epic+Module"
     ]
    ],
    [
     "status_id",
     "*",
     null
    ],
    [
     "cf:Module",
     "=",
     [
      "39 S/4HANA Architecture",
      "40 Fiori Administration",
      "41 Gateway & OData"
     ]
    ]
   ],
   "columns": [
    "cf:Curriculum ID",
    "subject",
    "status",
    "estimated_hours",
    "spent_hours"
   ],
   "group_by": "cf:Module",
   "totals": [
    "estimated_hours",
    "spent_hours"
   ],
   "sort": [
    [
     "id",
     "asc"
    ]
   ]
  },
  {
   "name": "Dashboard: security progress",
   "roles": "public",
   "filters": [
    [
     "assigned_to_id",
     "=",
     [
      "me"
     ]
    ],
    [
     "tracker_id",
     "!",
     [
      "tracker:Epic+Module"
     ]
    ],
    [
     "status_id",
     "*",
     null
    ],
    [
     "cf:Module",
     "=",
     [
      "14 User Administration",
      "42 SAP Security",
      "43 Certificates"
     ]
    ]
   ],
   "columns": [
    "cf:Curriculum ID",
    "subject",
    "status",
    "estimated_hours",
    "spent_hours"
   ],
   "group_by": "cf:Module",
   "totals": [
    "estimated_hours",
    "spent_hours"
   ],
   "sort": [
    [
     "id",
     "asc"
    ]
   ]
  },
  {
   "name": "Dashboard: HA/DR progress",
   "roles": "public",
   "filters": [
    [
     "assigned_to_id",
     "=",
     [
      "me"
     ]
    ],
    [
     "tracker_id",
     "!",
     [
      "tracker:Epic+Module"
     ]
    ],
    [
     "status_id",
     "*",
     null
    ],
    [
     "cf:Module",
     "=",
     [
      "36 HANA HA",
      "37 HANA DR",
      "49 HA & Clustering",
      "50 Backup Strategy",
      "51 Disaster Recovery"
     ]
    ]
   ],
   "columns": [
    "cf:Curriculum ID",
    "subject",
    "status",
    "estimated_hours",
    "spent_hours"
   ],
   "group_by": "cf:Module",
   "totals": [
    "estimated_hours",
    "spent_hours"
   ],
   "sort": [
    [
     "id",
     "asc"
    ]
   ]
  },
  {
   "name": "Dashboard: automation progress",
   "roles": "public",
   "filters": [
    [
     "assigned_to_id",
     "=",
     [
      "me"
     ]
    ],
    [
     "tracker_id",
     "!",
     [
      "tracker:Epic+Module"
     ]
    ],
    [
     "status_id",
     "*",
     null
    ],
    [
     "cf:Module",
     "=",
     [
      "03 Linux Shell Scripting",
      "53 Automation",
      "54 Observability"
     ]
    ]
   ],
   "columns": [
    "cf:Curriculum ID",
    "subject",
    "status",
    "estimated_hours",
    "spent_hours"
   ],
   "group_by": "cf:Module",
   "totals": [
    "estimated_hours",
    "spent_hours"
   ],
   "sort": [
    [
     "id",
     "asc"
    ]
   ]
  },
  {
   "name": "Dashboard: assessment scores",
   "roles": "public",
   "filters": [
    [
     "assigned_to_id",
     "=",
     [
      "me"
     ]
    ],
    [
     "status_id",
     "*",
     null
    ],
    [
     "tracker_id",
     "=",
     [
      "tracker:Assessment"
     ]
    ]
   ],
   "columns": [
    "cf:Curriculum ID",
    "subject",
    "status",
    "cf:Assessment Score"
   ],
   "group_by": "fixed_version",
   "totals": [],
   "sort": [
    [
     "id",
     "asc"
    ]
   ]
  },
  {
   "name": "Dashboard: open incidents",
   "roles": "public",
   "filters": [
    [
     "assigned_to_id",
     "=",
     [
      "me"
     ]
    ],
    [
     "status_id",
     "o",
     null
    ],
    [
     "tracker_id",
     "=",
     [
      "tracker:Troubleshooting Incident+Production Incident"
     ]
    ]
   ],
   "columns": [
    "cf:Curriculum ID",
    "subject",
    "status",
    "cf:Incident Severity"
   ],
   "group_by": "cf:Incident Severity",
   "totals": [],
   "sort": [
    [
     "id",
     "asc"
    ]
   ]
  },
  {
   "name": "Dashboard: incidents by status",
   "roles": "public",
   "filters": [
    [
     "assigned_to_id",
     "=",
     [
      "me"
     ]
    ],
    [
     "status_id",
     "*",
     null
    ],
    [
     "tracker_id",
     "=",
     [
      "tracker:Troubleshooting Incident+Production Incident"
     ]
    ]
   ],
   "columns": [
    "cf:Curriculum ID",
    "subject",
    "status",
    "cf:Incident Severity",
    "closed_on"
   ],
   "group_by": "status",
   "totals": [],
   "sort": [
    [
     "id",
     "asc"
    ]
   ]
  },
  {
   "name": "Dashboard: RCA completion",
   "roles": "public",
   "filters": [
    [
     "assigned_to_id",
     "=",
     [
      "me"
     ]
    ],
    [
     "status_id",
     "*",
     null
    ],
    [
     "tracker_id",
     "=",
     [
      "tracker:RCA"
     ]
    ]
   ],
   "columns": [
    "cf:Curriculum ID",
    "subject",
    "status",
    "closed_on"
   ],
   "group_by": null,
   "totals": [],
   "sort": [
    [
     "id",
     "asc"
    ]
   ]
  },
  {
   "name": "Dashboard: project completion",
   "roles": "public",
   "filters": [
    [
     "assigned_to_id",
     "=",
     [
      "me"
     ]
    ],
    [
     "status_id",
     "*",
     null
    ],
    [
     "tracker_id",
     "=",
     [
      "tracker:Project"
     ]
    ]
   ],
   "columns": [
    "cf:Curriculum ID",
    "subject",
    "status",
    "cf:Assessment Score",
    "estimated_hours",
    "spent_hours"
   ],
   "group_by": null,
   "totals": [
    "estimated_hours",
    "spent_hours"
   ],
   "sort": [
    [
     "id",
     "asc"
    ]
   ]
  },
  {
   "name": "Dashboard: capstone progress",
   "roles": "public",
   "filters": [
    [
     "assigned_to_id",
     "=",
     [
      "me"
     ]
    ],
    [
     "status_id",
     "*",
     null
    ],
    [
     "tracker_id",
     "=",
     [
      "tracker:Capstone Task"
     ]
    ]
   ],
   "columns": [
    "cf:Curriculum ID",
    "subject",
    "status",
    "cf:Assessment Score",
    "estimated_hours",
    "spent_hours"
   ],
   "group_by": null,
   "totals": [
    "estimated_hours",
    "spent_hours"
   ],
   "sort": [
    [
     "id",
     "asc"
    ]
   ]
  },
  {
   "name": "Dashboard: interview readiness",
   "roles": "public",
   "filters": [
    [
     "assigned_to_id",
     "=",
     [
      "me"
     ]
    ],
    [
     "status_id",
     "*",
     null
    ],
    [
     "tracker_id",
     "=",
     [
      "tracker:Interview Question"
     ]
    ]
   ],
   "columns": [
    "cf:Curriculum ID",
    "subject",
    "status",
    "cf:Interview Topic"
   ],
   "group_by": "status",
   "totals": [],
   "sort": [
    [
     "id",
     "asc"
    ]
   ]
  },
  {
   "name": "Dashboard: by SAP component",
   "roles": "public",
   "filters": [
    [
     "assigned_to_id",
     "=",
     [
      "me"
     ]
    ],
    [
     "tracker_id",
     "!",
     [
      "tracker:Epic+Module"
     ]
    ],
    [
     "status_id",
     "*",
     null
    ]
   ],
   "columns": [
    "cf:Curriculum ID",
    "subject",
    "status",
    "estimated_hours",
    "spent_hours"
   ],
   "group_by": "category",
   "totals": [
    "estimated_hours",
    "spent_hours"
   ],
   "sort": [
    [
     "id",
     "asc"
    ]
   ]
  },
  {
   "name": "Dashboard: change requests",
   "roles": "public",
   "filters": [
    [
     "assigned_to_id",
     "=",
     [
      "me"
     ]
    ],
    [
     "status_id",
     "*",
     null
    ],
    [
     "tracker_id",
     "=",
     [
      "tracker:Change Request"
     ]
    ]
   ],
   "columns": [
    "cf:Curriculum ID",
    "subject",
    "status"
   ],
   "group_by": null,
   "totals": [],
   "sort": [
    [
     "id",
     "asc"
    ]
   ]
  },
  {
   "name": "Operations: daily checks",
   "roles": "public",
   "filters": [
    [
     "status_id",
     "*",
     null
    ],
    [
     "subject",
     "~",
     [
      "Daily Basis health check"
     ]
    ]
   ],
   "columns": [
    "cf:Curriculum ID",
    "subject",
    "assigned_to",
    "status",
    "updated_on"
   ],
   "group_by": null,
   "totals": [],
   "sort": [
    [
     "updated_on",
     "desc"
    ]
   ]
  },
  {
   "name": "Instructor: review queue",
   "roles": "staff",
   "filters": [
    [
     "status_id",
     "=",
     [
      "status:Review"
     ]
    ]
   ],
   "columns": [
    "cf:Curriculum ID",
    "subject",
    "assigned_to",
    "updated_on"
   ],
   "group_by": null,
   "totals": [],
   "sort": [
    [
     "updated_on",
     "asc"
    ]
   ]
  },
  {
   "name": "Instructor: blocked students",
   "roles": "staff",
   "filters": [
    [
     "status_id",
     "=",
     [
      "status:Blocked"
     ]
    ]
   ],
   "columns": [
    "cf:Curriculum ID",
    "subject",
    "updated_on"
   ],
   "group_by": "assigned_to",
   "totals": [],
   "sort": [
    [
     "updated_on",
     "asc"
    ]
   ]
  },
  {
   "name": "Instructor: progress by student",
   "roles": "staff",
   "filters": [
    [
     "tracker_id",
     "!",
     [
      "tracker:Epic+Module"
     ]
    ],
    [
     "status_id",
     "*",
     null
    ]
   ],
   "columns": [
    "cf:Curriculum ID",
    "subject",
    "status",
    "estimated_hours",
    "spent_hours"
   ],
   "group_by": "assigned_to",
   "totals": [
    "estimated_hours",
    "spent_hours"
   ],
   "sort": [
    [
     "id",
     "asc"
    ]
   ]
  },
  {
   "name": "Instructor: progress by version",
   "roles": "staff",
   "filters": [
    [
     "tracker_id",
     "!",
     [
      "tracker:Epic+Module"
     ]
    ],
    [
     "status_id",
     "*",
     null
    ]
   ],
   "columns": [
    "cf:Curriculum ID",
    "subject",
    "assigned_to",
    "status",
    "estimated_hours",
    "spent_hours"
   ],
   "group_by": "fixed_version",
   "totals": [
    "estimated_hours",
    "spent_hours"
   ],
   "sort": [
    [
     "id",
     "asc"
    ]
   ]
  },
  {
   "name": "Instructor: module completion by student",
   "roles": "staff",
   "filters": [
    [
     "status_id",
     "*",
     null
    ],
    [
     "tracker_id",
     "=",
     [
      "tracker:Module"
     ]
    ]
   ],
   "columns": [
    "cf:Curriculum ID",
    "subject",
    "status",
    "done_ratio"
   ],
   "group_by": "assigned_to",
   "totals": [],
   "sort": [
    [
     "id",
     "asc"
    ]
   ]
  },
  {
   "name": "Instructor: compare one task",
   "roles": "staff",
   "filters": [
    [
     "status_id",
     "*",
     null
    ],
    [
     "cf:Curriculum ID",
     "=",
     [
      "BASIS-LAB-001"
     ]
    ]
   ],
   "columns": [
    "cf:Curriculum ID",
    "assigned_to",
    "status",
    "spent_hours",
    "cf:Instructor Review"
   ],
   "group_by": null,
   "totals": [],
   "sort": [
    [
     "id",
     "asc"
    ]
   ]
  },
  {
   "name": "Instructor: scores",
   "roles": "staff",
   "filters": [
    [
     "status_id",
     "*",
     null
    ],
    [
     "tracker_id",
     "=",
     [
      "tracker:Assessment+Project+Capstone Task"
     ]
    ]
   ],
   "columns": [
    "cf:Curriculum ID",
    "subject",
    "assigned_to",
    "status",
    "cf:Assessment Score"
   ],
   "group_by": "fixed_version",
   "totals": [],
   "sort": [
    [
     "id",
     "asc"
    ]
   ]
  },
  {
   "name": "Instructor: faults to prepare",
   "roles": "staff",
   "filters": [
    [
     "status_id",
     "=",
     [
      "status:Assigned"
     ]
    ],
    [
     "tracker_id",
     "=",
     [
      "tracker:Troubleshooting Incident+Production Incident+Capstone Task"
     ]
    ]
   ],
   "columns": [
    "cf:Curriculum ID",
    "subject",
    "assigned_to",
    "cf:Incident Severity"
   ],
   "group_by": "assigned_to",
   "totals": [],
   "sort": [
    [
     "id",
     "asc"
    ]
   ]
  },
  {
   "name": "Instructor: stale work",
   "roles": "staff",
   "filters": [
    [
     "status_id",
     "=",
     [
      "status:In Progress"
     ]
    ],
    [
     "updated_on",
     "<t-",
     [
      "7"
     ]
    ]
   ],
   "columns": [
    "cf:Curriculum ID",
    "subject",
    "assigned_to",
    "updated_on"
   ],
   "group_by": "assigned_to",
   "totals": [],
   "sort": [
    [
     "updated_on",
     "asc"
    ]
   ]
  }
 ],
 "wiki": [
  {
   "title": "Wiki",
   "parent": null,
   "text": "# SAP BASIS - Complete Training Basic to Expert\n\nSAP Basis programme from IT and Linux fundamentals to SAP technical consultant: Linux, networking, databases, SAP architecture, installation, core Basis administration, transports, monitoring, performance, SAP HANA administration, backup and recovery, HA/DR, S/4HANA and Fiori, security and certificates, system copy and refresh, upgrade and migration, cloud, automation, observability, production support and troubleshooting, in 59 modules ending in an enterprise landscape capstone. Every topic follows Concept -> Architecture -> Configuration -> Administration -> Monitoring -> Troubleshooting -> Recovery -> Automation -> Project -> Production Support. One shared project; every student has a personal copy of each issue.\n\n## How to work an issue\n\n1. Open your next issue from the saved query *My next tasks*.\n2. Set the status to **In Progress** and do the steps. Log time at the end of every session.\n3. Set **Testing**, check every expected result, attach the evidence.\n4. Set **Review**. The instructor sets **Completed** or **Reopened**.\n\n## Pages\n\n- [[Lab_Environment]]\n- [[Capstone_Landscape]]\n- [[SAP_Ports]]\n- [[Lab_Format]]\n- [[Incident_Flow]]\n- [[Daily_Health_Check]]\n- [[Projects]]\n- [[Incident_Bank]]\n- [[Interview_Bank]]\n- [[Documentation_Set]]\n- [[Workflow_and_Statuses]]\n- [[Assessment_and_Grading]]\n- [[Completion_Criteria]]\n- [[Dashboard_Guide]]\n- [[Tool_Index]]\n- [[Module_Index]]"
  },
  {
   "title": "Lab_Environment",
   "text": "# Lab environment\n\n| Environment | What it is | Used from |\n|---|---|---|\n| Workbook or design exercise | Paper, diagrams and documents | Module 01 |\n| Linux lab server | Two or three Linux virtual machines per student on a distribution supported for SAP | Module 02 |\n| SAP HANA lab system | SAP HANA systems installed by the student (two for replication, a third for DR) | Module 05 (practice database), module 30 |\n| SAP ABAP lab system | ABAP systems on HANA installed by the student: a development and a quality system, plus a web dispatcher | Module 07 (instructor system), module 08 |\n| HA/DR lab cluster | Two-node cluster with the high-availability add-on, replicated HANA pair, DR host | Module 36 |\n| Monitoring lab stack | Monitoring host with Prometheus, Grafana, Alertmanager and a log store | Module 54 |\n| Cloud account or design exercise | A cloud account if the course provides one; otherwise design work | Module 52 |\n\n## What the instructor provides\n\n- Virtualization capacity for the lab hosts (HANA needs memory: plan the largest hosts for it)\n- SAP installation media, licences and download access; the software is not part of this project\n- An existing SAP system for the first look in module 07\n- Prepared faults for every troubleshooting incident, production incident and capstone failure\n- Prepared transport requests, dumps, slow reports and test programs named in the labs\n\n## Authorized use\n\nFailure injection, hardening tests and every other disruptive exercise are performed only on the course lab systems. Nothing from this course is tried on a productive system.\n\nTransactions, commands and file names can differ by release and distribution; where a lab names a tool that your release has replaced, use the successor and note it.",
   "parent": "Wiki"
  },
  {
   "title": "Capstone_Landscape",
   "text": "# Capstone: Global Enterprise SAP Landscape\n\n```\n                    Internet\n                       |\n                SAP Web Dispatcher\n                       |\n          +------------+------------+\n          |                         |\n       Fiori                     SAP GUI\n          |                         |\n          +------------+------------+\n                       |\n                S/4HANA Application\n                       |\n          +------------+------------+\n          |            |            |\n        PAS          AAS          ASCS\n                                    |\n                                   ERS\n                                    |\n                              SAP HANA\n                                    |\n                             HANA Secondary\n```\n\nImplemented: Linux servers, S/4HANA, HANA, ASCS, ERS, PAS, AAS, Web Dispatcher, Fiori, users, roles, RFC, jobs, spool, transports, monitoring, backup, HA, DR, security, certificates, automation.\n\nOperations performed: installation, administration, monitoring, security, transport, backup, recovery, HA, DR, upgrade strategy, migration strategy, automation, troubleshooting of 13 injected failures.",
   "parent": "Wiki"
  },
  {
   "title": "SAP_Ports",
   "text": "# SAP ports (NN = instance number)\n\n| Component | Port | Used by |\n|---|---|---|\n| Dispatcher | 32NN | SAP GUI |\n| Gateway | 33NN | RFC, registered programs |\n| Message server | 36NN | Load-balanced logon |\n| Message server HTTP | 81NN | Web dispatcher server list |\n| Message server internal | 39NN | Application servers |\n| ICM HTTP / HTTPS | As configured, often 80NN / 443NN | Browser, web dispatcher, OData |\n| Start service | 5NN13 / 5NN14 | sapcontrol, management tools, monitoring |\n| Host agent | 1128 / 1129 | Management and monitoring |\n| HANA SQL system database | 3NN13 | Clients, administration |\n| HANA SQL first tenant | 3NN15 | Application server |\n| HANA further tenants and internal | 3NN40 and up; internal ranges | Tenants, replication, services |\n| SAProuter | 3299 | Support connection, routed GUI |\n| SSH | 22 | Administration, automation |\n| NFS | 2049 | /sapmnt, transport directory |\n\nConfirm the ports of your release in the official port list before building firewall rules; your port matrix from module 04 is the binding document for the lab.",
   "parent": "Wiki"
  },
  {
   "title": "Lab_Format",
   "text": "# Practical lab format\n\nEvery Configuration, Installation Lab, Administration Lab and HANA Lab issue has these sections:\n\nLAB ID - Title - Objective - Business Scenario - Architecture - Prerequisites - Environment - Commands / Configuration - Procedure - Expected Result - Validation - Troubleshooting - Evidence - Documentation - Deliverable\n\nLab IDs are BASIS-LAB-001 onwards. Prerequisites are the *blocked by* relations of the issue.",
   "parent": "Wiki"
  },
  {
   "title": "Incident_Flow",
   "text": "# Incident flow\n\nEvery troubleshooting incident and production incident follows:\n\nIncident -> Impact -> Detection -> Initial Checks -> Evidence -> Root Cause -> Fix -> Validation -> RCA -> Prevention\n\nCapstone failures follow:\n\nFailure -> Detection -> Diagnosis -> Root Cause -> Recovery -> Validation -> RCA -> Preventive Action\n\nThe student fills the issue fields **Business Impact**, **Root Cause** and **Resolution**; **Incident Severity** is preset and may be corrected by the instructor.\n\n## RCA document\n\n1. Summary\n2. Timeline\n3. Impact\n4. Detection\n5. Root cause (five-whys chain)\n6. Trigger and contributing factors\n7. Corrective action\n8. Preventive actions with owner and date\n9. Lessons learned\n\n| Severity | Meaning |\n|---|---|\n| P1 - Critical | System or core business process down |\n| P2 - High | Major function degraded, workaround hard |\n| P3 - Medium | Limited impact or workaround exists |\n| P4 - Low | Minor or cosmetic |\n\nThe programme contains 130 troubleshooting incidents, 12 production incidents and 13 capstone failures. The instructor prepares each fault before the issue is started.",
   "parent": "Wiki"
  },
  {
   "title": "Daily_Health_Check",
   "text": "# Daily Basis health check\n\n| Check | Where | Healthy when |\n|---|---|---|\n| SAP availability | sapcontrol GetSystemInstanceList, logon | All instances green, logon works |\n| Application servers | SM51 | All expected servers active |\n| Work processes | SM50, SM66 | Free processes of each type, no unexplained long runners |\n| System logs | SM21 | No new errors of high priority |\n| Dumps | ST22 | No new dump types, counts within baseline |\n| Jobs | SM37 | No cancelled or delayed critical jobs |\n| Locks | SM12 | No old lock entries |\n| Updates | SM13 | Update active, no failed requests |\n| RFC | SM58, SMQ1, SMQ2, SM59 tests | No stuck calls or queues |\n| Spool | SP01 | No mass of failed output requests |\n| Disk | df, ST06 | All filesystems below threshold |\n| CPU | ST06, top | Within baseline |\n| Memory | ST06, ST02, free | No swapping, buffers healthy |\n| HANA | HDB info, cockpit or DBACOCKPIT | All services active, no high alerts, memory within limit |\n| Backup | Backup catalog | Last data and log backups successful and recent |\n| Replication | systemReplicationStatus.py | Active and in sync |\n| Certificates | STRUST, expiry script | Nothing expires within the warning period |\n| Interfaces | Interface monitors, queues | No backlog or failed messages |\n\nRedmine has no built-in recurring issues. The *Daily Basis health check* issue of module 57 is the template: copy it for each day of operation (issue > Copy), or let the automated health check of module 57 create the report. The saved query *Operations: daily checks* lists the copies.",
   "parent": "Wiki"
  },
  {
   "title": "Projects",
   "text": "# Hands-on projects\n\nEach project closes the module in which its skills are built.\n\n| Project | Title | Module | Issue |\n|---|---|---|---|\n| Project 1 | Linux SAP Server Preparation | 04 Networking | PROJECT-001 |\n| Project 2 | SAP Installation | 08 SAP Installation | PROJECT-002 |\n| Project 3 | SAP Start/Stop and Instance Administration | 13 Work Processes | PROJECT-003 |\n| Project 4 | SAP User Administration | 14 User Administration | PROJECT-004 |\n| Project 5 | Background Job Management | 15 Background Jobs | PROJECT-005 |\n| Project 15 | SAP Web Dispatcher | 22 Web Dispatcher | PROJECT-006 |\n| Project 6 | Transport Management | 23 Transport Management | PROJECT-007 |\n| Project 7 | SAP Monitoring | 26 Monitoring | PROJECT-008 |\n| Project 8 | SAP Performance Troubleshooting | 28 Performance | PROJECT-009 |\n| Project 9 | SAP HANA Installation | 31 HANA Installation | PROJECT-010 |\n| Project 10 | HANA Administration | 32 HANA Administration | PROJECT-011 |\n| Project 11 | HANA Backup & Recovery | 35 HANA Recovery | PROJECT-012 |\n| Project 12 | HANA System Replication | 36 HANA HA | PROJECT-013 |\n| Project 13 | S/4HANA Technical Administration | 39 S/4HANA Architecture | PROJECT-014 |\n| Project 14 | Fiori Administration | 40 Fiori Administration | PROJECT-015 |\n| Security Hardening Project (authorized lab) | Security Hardening Project (authorized lab) | 42 SAP Security | PROJECT-016 |\n| Project 18 | System Copy | 44 System Copy | PROJECT-017 |\n| Project 19 | System Refresh (QAS Refresh Project) | 45 System Refresh | PROJECT-018 |\n| DEV Refresh Project | DEV Refresh Project | 45 System Refresh | PROJECT-019 |\n| Project 20 | SAP Upgrade | 47 Upgrade | PROJECT-020 |\n| Project 21 | ECC to S/4HANA Migration Concepts | 48 Migration | PROJECT-021 |\n| Project 16 | SAP HA | 49 HA & Clustering | PROJECT-022 |\n| Project 17 | SAP DR (Complete SAP DR Project) | 51 Disaster Recovery | PROJECT-023 |\n| Project 23 | SAP Basis Automation with Ansible | 53 Automation | PROJECT-024 |\n| Project 22 | SAP Monitoring with Grafana | 54 Observability | PROJECT-025 |\n| SAP Basis Automated Health Check Project | SAP Basis Automated Health Check Project | 57 Production Support | PROJECT-026 |\n| Project 24 | Enterprise Production Support | 57 Production Support | PROJECT-027 |",
   "parent": "Wiki"
  },
  {
   "title": "Incident_Bank",
   "text": "# Real-world incident bank\n\n195 production scenarios. The first three groups are worked on the lab systems as issues; the fourth is worked on paper in the incident bank packs of module 58.\n\n## Troubleshooting incidents\n\n- INC-001 Disk full on a system filesystem (P2, module 02)\n- INC-002 Filesystem mounted read-only (P1, module 02)\n- INC-003 NFS share unavailable and processes hang (P1, module 02)\n- INC-004 SSH login fails for the administrator user (P3, module 02)\n- INC-005 Service does not start after reboot (P3, module 02)\n- INC-006 DNS failure: host name does not resolve (P2, module 04)\n- INC-007 Port blocked between two servers (P2, module 04)\n- INC-008 Installer aborts in the prerequisite or database load phase (P3, module 08)\n- INC-009 Installation fails on host name resolution (P3, module 08)\n- INC-010 sapstartsrv not responding: sapcontrol returns a connection error (P2, module 09)\n- INC-011 Kernel mismatch: instance does not start after a kernel change (P1, module 10)\n- INC-012 Instance won't start: database not reachable (P1, module 11)\n- INC-013 Instance won't start: port already in use or leftover processes (P1, module 11)\n- INC-014 Instance won't start: profile or directory problem (P1, module 11)\n- INC-015 Instance does not start after a parameter change (P1, module 12)\n- INC-016 Work process exhaustion: all dialog processes occupied (P1, module 13)\n- INC-017 Long-running dialog process in PRIV mode (P2, module 13)\n- INC-018 User locked after failed logons and cannot work (P3, module 14)\n- INC-019 Authorization issue: transaction fails for a user after a role change (P3, module 14)\n- INC-020 Job cancelled: missing variant (P3, module 15)\n- INC-021 Job delayed: no free background work process (P2, module 15)\n- INC-022 Job running too long (P2, module 15)\n- INC-023 Job fails with an authorization error (P3, module 15)\n- INC-024 Spool issue: output requests stay in status waiting (P3, module 16)\n- INC-025 Spool overflow: no more spool requests can be created (P2, module 16)\n- INC-026 Lock issue: old lock entries remain after a user's session ended (P3, module 17)\n- INC-027 Lock table overflow (P1, module 17)\n- INC-028 Update terminated for many users after a transport (P2, module 18)\n- INC-029 Update backlog: update deactivated after a database error (P1, module 18)\n- INC-030 RFC failure: destination returns logon error (P2, module 19)\n- INC-031 Gateway failure: registered program cannot register (P2, module 19)\n- INC-032 Transactional RFC entries pile up (P2, module 19)\n- INC-033 Message server failure: group logon fails while direct logon works (P2, module 20)\n- INC-034 HTTP failure: service returns forbidden or not found (P3, module 21)\n- INC-035 HTTPS failure: handshake error in the browser (P2, module 21)\n- INC-036 Port unavailable: the manager cannot bind its port (P2, module 21)\n- INC-037 Web Dispatcher failure: 503 no server available (P1, module 22)\n- INC-038 Web Dispatcher returns a certificate error only for external users (P2, module 22)\n- INC-039 Transport failure: import hangs and never ends (P2, module 23)\n- INC-040 Transport failure: return code 8 on import (P3, module 23)\n- INC-041 Transport failure: return code 12 or tool cannot connect (P2, module 23)\n- INC-042 Import queue is empty although requests were released (P3, module 23)\n- INC-043 SAP Note issue: note cannot be downloaded or implemented (P3, module 25)\n- INC-044 Patch issue: support package import stops in a phase (P2, module 25)\n- INC-045 Dispatcher failure: dispatcher trace shows the instance shutting down (P1, module 27)\n- INC-046 Work processes restart repeatedly with errors in the trace (P2, module 27)\n- INC-047 Performance degradation: high wait time for all users (P2, module 28)\n- INC-048 Performance degradation: high database time (P2, module 28)\n- INC-049 Performance degradation after a restart (P3, module 28)\n- INC-050 CPU high on the application server host (P2, module 28)\n- INC-051 Memory exhausted: host is swapping (P1, module 28)\n- INC-052 HANA installation fails in the prerequisite check or service start (P3, module 31)\n- INC-053 HANA service stopped: index server of one tenant is down (P1, module 32)\n- INC-054 Connection failure: application cannot connect to HANA (P1, module 32)\n- INC-055 HANA disk full on the trace or log volume (P1, module 32)\n- INC-056 HANA user locked: technical user of the application (P1, module 33)\n- INC-057 HANA backup failure: data backup ends with error (P2, module 34)\n- INC-058 Log backups fail and the log volume fills (P1, module 34)\n- INC-059 Recovery fails: a log backup is missing (P1, module 35)\n- INC-060 Replication broken: secondary shows error and is out of sync (P2, module 36)\n- INC-061 Takeover done but the application cannot connect (P1, module 36)\n- INC-062 DR issue: DR site cannot be activated because the licence or keys are missing (P1, module 37)\n- INC-063 HANA memory issue: out-of-memory events during reporting (P1, module 38)\n- INC-064 SQL performance: one statement slows the whole system (P2, module 38)\n- INC-065 HANA CPU saturation (P2, module 38)\n- INC-066 Fiori failure: launchpad does not load (P1, module 40)\n- INC-067 Fiori failure: tile is missing for one user (P3, module 40)\n- INC-068 Fiori failure: app shows old version after a transport (P3, module 40)\n- INC-069 OData failure: 401 unauthorized (P3, module 41)\n- INC-070 OData failure: 403 forbidden (P3, module 41)\n- INC-071 OData failure: 404 not found or service inactive (P3, module 41)\n- INC-072 OData failure: 500 internal server error from the back end (P2, module 41)\n- INC-073 Users cannot log on after password policy parameters were changed (P2, module 42)\n- INC-074 Interface stops after gateway access lists were tightened (P2, module 42)\n- INC-075 Certificate expiry: users get browser errors on Monday morning (P1, module 43)\n- INC-076 Certificate problem: chain incomplete for some clients (P2, module 43)\n- INC-077 Outbound HTTPS call fails with a trust error (P2, module 43)\n- INC-078 System copy issue: target does not start after the copy (P2, module 44)\n- INC-079 System copy issue: copied system sends messages to production partners (P1, module 44)\n- INC-080 Refresh issue: jobs from the source start running in the refreshed system (P1, module 45)\n- INC-081 Refresh issue: users of the target system are gone (P2, module 45)\n- INC-082 Refresh issue: logical system conversion runs for many hours (P3, module 45)\n- INC-083 System accepts logons only from the emergency user: licence expired (P1, module 46)\n- INC-084 Upgrade issue: tool stops with an error in a preprocessing phase (P2, module 47)\n- INC-085 Upgrade issue: dumps after go-live in modified objects (P2, module 47)\n- INC-086 Migration issue: export or import of one large table fails repeatedly (P2, module 48)\n- INC-087 HA failover issue: cluster does not fail over because fencing fails (P1, module 49)\n- INC-088 HA failover issue: locks are lost after central services failover (P1, module 49)\n- INC-089 HA failover issue: resource fails back and forth (P2, module 49)\n- INC-090 Backup issue: restore test shows that backups of one filesystem were empty for weeks (P1, module 50)\n- INC-091 DR issue: application servers at the DR site do not start after database takeover (P1, module 51)\n- INC-092 Cloud issue: virtual address does not move after a cluster failover (P1, module 52)\n- INC-093 OS: /usr/sap filesystem full, instance processes die (P1, module 56)\n- INC-094 OS: CPU high from a runaway non-SAP process (P2, module 56)\n- INC-095 OS: memory exhausted and the kernel kills a process (P1, module 56)\n- INC-096 OS: NFS unavailable for /sapmnt on an application server (P1, module 56)\n- INC-097 OS: process failure, start service of one instance is gone (P2, module 56)\n- INC-098 OS: time jump on a host breaks logons and jobs (P2, module 56)\n- INC-099 OS: inode exhaustion although space is free (P2, module 56)\n- INC-100 OS: host reboots and the SAP system does not come back (P1, module 56)\n- INC-101 SAP: system unavailable, no instance answers (P1, module 56)\n- INC-102 SAP: instance won't start after a host name change (P1, module 56)\n- INC-103 SAP: work process unavailable, all update processes stopped (P1, module 56)\n- INC-104 SAP: dispatcher failure, dispatcher ends shortly after start (P1, module 56)\n- INC-105 SAP: message server failure, application servers lose contact (P1, module 56)\n- INC-106 SAP: gateway failure, external program connections refused (P2, module 56)\n- INC-107 SAP: ICM failure, all HTTP requests hang (P1, module 56)\n- INC-108 SAP: lock issue, mass locks from one batch job block users (P2, module 56)\n- INC-109 SAP: update failure, V2 updates pile up (P3, module 56)\n- INC-110 SAP: job failure, a whole job chain stops overnight (P2, module 56)\n- INC-111 SAP: spool failure, spool work process in error (P3, module 56)\n- INC-112 SAP: RFC failure, calls to one system time out (P2, module 56)\n- INC-113 SAP: logon possible but every transaction dumps (P1, module 56)\n- INC-114 SAP: number range buffer or enqueue timeouts after failover (P2, module 56)\n- INC-115 HANA: HANA unavailable after a host restart (P1, module 56)\n- INC-116 HANA: memory exhaustion, system near the allocation limit (P1, module 56)\n- INC-117 HANA: disk full on the data volume (P1, module 56)\n- INC-118 HANA: backup failure, backup destination unreachable (P2, module 56)\n- INC-119 HANA: replication broken after network maintenance (P2, module 56)\n- INC-120 HANA: SQL performance, statement plan changed after an update (P2, module 56)\n- INC-121 HANA: service stopped, name server restarts repeatedly (P1, module 56)\n- INC-122 HANA: connection failure, connection limit reached (P2, module 56)\n- INC-123 HANA: long savepoints freeze commits (P2, module 56)\n- INC-124 Network: DNS failure after a resolver change (P1, module 56)\n- INC-125 Network: port blocked after a firewall rule update (P2, module 56)\n- INC-126 Network: firewall issue, idle connections dropped (P3, module 56)\n- INC-127 Network: certificate problem, system-to-system HTTPS fails after a CA change (P2, module 56)\n- INC-128 Network: load balancer failure, health check marks all servers down (P1, module 56)\n- INC-129 Network: high latency between application server and database (P2, module 56)\n- INC-130 Multi-fault case: Monday morning after a maintenance weekend (P1, module 56)\n\n## Production incidents\n\n- PRD-001 Month-end: users report the system is extremely slow (P1)\n- PRD-002 Interface to the bank has delivered nothing since last night (P2)\n- PRD-003 All users are logged off and cannot log on again (P1)\n- PRD-004 Background jobs have been delayed for hours (P2)\n- PRD-005 Printing fails in the warehouse (P3)\n- PRD-006 Fiori launchpad shows an error page for everyone (P1)\n- PRD-007 Transport to production failed during the release window (P2)\n- PRD-008 Database log volume is filling fast (P1)\n- PRD-009 One application server restarts every few hours (P2)\n- PRD-010 Users in one country cannot connect (P2)\n- PRD-011 Security team reports a default password on a standard user (P2)\n- PRD-012 Disk space alert on the transport directory (P3)\n\n## Capstone failure injection\n\n- FAIL-001 Failure 01: stop SAP instance\n- FAIL-002 Failure 02: stop HANA service\n- FAIL-003 Failure 03: fill test filesystem\n- FAIL-004 Failure 04: stop application server\n- FAIL-005 Failure 05: break test RFC\n- FAIL-006 Failure 06: expire test certificate\n- FAIL-007 Failure 07: stop Web Dispatcher\n- FAIL-008 Failure 08: create test job failure\n- FAIL-009 Failure 09: create test lock\n- FAIL-010 Failure 10: create test update failure\n- FAIL-011 Failure 11: break HANA replication\n- FAIL-012 Failure 12: simulate backup failure\n- FAIL-013 Failure 13: simulate network connectivity failure\n\n## Further scenarios\n\n1. Database full: HANA data volume cannot grow because the storage pool is exhausted\n2. SAP unavailable after an unannounced storage maintenance\n3. Instance won't start because the secure store was overwritten during a copy\n4. Dispatcher down on one server after shared memory was removed by an administrator\n5. Work process exhausted by a mass RFC caller from a partner system\n6. CPU high on the HANA host during a statistics collection job\n7. Filesystem full in the transport directory during a release import\n8. HANA backup failure because the backup tool agent was updated\n9. HANA replication failure after a password change of the replication user\n10. Transport failure because the transport directory was mounted read-only on one host\n11. Web Dispatcher failure after a profile change with a wrong back-end port\n12. Certificate expiry on the HANA SQL port used by an external reporting tool\n13. User locked: the batch user of the job scheduler is locked on a Sunday\n14. Authorization issue for all users after a role transport with empty profiles\n15. Job failure of the daily billing run because of a missing spool device\n16. Spool issue: thousands of spool requests created by a looping job\n17. Update failure caused by a full table space equivalent: volume quota reached\n18. Lock issue: enqueue table full during mass data load\n19. Performance degradation every hour on the hour traced to a monitoring job\n20. Long-running SQL from an ad-hoc query in the reporting client\n21. Network failure on one network card of a bonded pair\n22. Kernel mismatch between application servers after a partial patch\n23. SAP Note issue: correction overwritten by a later support package\n24. Patch issue: database client and server revisions do not fit after an update\n25. Fiori failure: launchpad empty after a role transport\n26. OData failure after the back-end alias destination was changed\n27. System copy issue: licence invalid on the target host\n28. Refresh issue: printers of production are used by the test system\n29. Upgrade issue: add-on not released for the target version stops the plan\n30. Migration issue: custom tables with inconsistent dictionary entries block the conversion\n31. HA failover issue: virtual host name not known to a partner system\n32. DR issue: backups at the DR site are older than the recovery point objective\n33. Time zone change on a host shifts all job start times\n34. Operating system patch replaces a library the kernel needs\n35. Monitoring is silent because the collector host itself is down\n36. Password of the database schema user expired\n37. Shared memory limits too low after an operating system upgrade\n38. Mail from SAP is not sent although the queue is processed\n39. Client was opened for changes in production and not closed again\n40. Emergency user was used and nobody knows by whom",
   "parent": "Wiki"
  },
  {
   "title": "Interview_Bank",
   "text": "# Interview bank\n\nFor every question prepare: question, short answer, detailed answer, real-world example, troubleshooting angle and common mistake.\n\n## SAP Basis Beginner (INT-001)\n\n1. What does a Basis administrator do?\n2. What is the difference between a system, an instance and a client?\n3. What is a SID and an instance number?\n4. What are the three layers of an SAP system?\n5. What is a transport request?\n6. What is the difference between a note and a support package?\n7. What is a kernel?\n8. How do you check whether an SAP system is running?\n\n## Linux (INT-002)\n\n1. How do you find what fills a filesystem?\n2. How do you extend a filesystem online?\n3. What is the difference between a process and a service?\n4. How do you read the logs of a failed service?\n5. What kernel settings does SAP need and how are they applied?\n6. How do you check which process listens on a port?\n7. What are the SAP operating system users and groups?\n8. How do you schedule and monitor a script?\n\n## Networking (INT-003)\n\n1. Which ports does an instance with number 00 use?\n2. What is the difference between connection refused and timeout?\n3. How do you prove that a firewall blocks a port?\n4. What is SAProuter?\n5. How does a GUI logon with load balancing work?\n6. What does a reverse proxy do?\n7. How does a TLS handshake work?\n8. How do you check name resolution problems?\n\n## SAP Architecture (INT-004)\n\n1. Explain the path of a dialog request\n2. What runs in central services and why?\n3. What is the enqueue replication server?\n4. What is the difference between a primary and an additional application server?\n5. What is the ICM?\n6. What is the gateway?\n7. What is the message server used for?\n8. How does the application server connect to HANA?\n\n## Installation (INT-005)\n\n1. What are the steps of an SAP installation?\n2. What do you check before starting the installer?\n3. What is the software provisioning manager?\n4. In which order are instances installed?\n5. What are the post-installation steps?\n6. How do you troubleshoot a failed installation phase?\n7. What is the Maintenance Planner?\n8. What is a distributed installation?\n\n## Kernel (INT-006)\n\n1. What is the SAP kernel?\n2. How do you patch a kernel?\n3. How do you check the kernel version?\n4. What is a rolling kernel switch?\n5. How do you roll back a kernel?\n6. What is the database-dependent part of the kernel?\n7. What does sapcpe do?\n8. What can go wrong after a kernel patch?\n\n## Work Process (INT-007)\n\n1. Which work process types exist?\n2. What happens when all dialog processes are busy?\n3. What is PRIV mode?\n4. How do you find what a work process is doing?\n5. What are operation modes?\n6. How do you size the number of work processes?\n7. How do you analyse the system when you cannot log on?\n8. What is the dispatcher queue?\n\n## Job (INT-008)\n\n1. What are job classes?\n2. Why would a job stay in status released?\n3. How do you analyse a cancelled job?\n4. What is an event-triggered job?\n5. What are the standard housekeeping jobs?\n6. How do you find long-running jobs?\n7. Who is the step user and why does it matter?\n8. How do you stop jobs from running after a system copy?\n\n## Transport (INT-009)\n\n1. Explain the transport landscape and routes\n2. What do return codes 4, 8 and 12 mean?\n3. What is the difference between workbench and customizing requests?\n4. What are the files of a transport and where are they?\n5. How do you import a request from the operating system?\n6. What is the domain controller?\n7. What happens when requests are imported in the wrong order?\n8. How do you handle a hanging import?\n\n## Monitoring (INT-010)\n\n1. What do you check every morning?\n2. How do you monitor work processes across servers?\n3. How do you read the system log?\n4. What do you check for the database?\n5. How do you monitor interfaces?\n6. What is the difference between monitoring and observability?\n7. Which alerts would you configure first?\n8. How do you avoid alert fatigue?\n\n## Performance (INT-011)\n\n1. What are the components of dialog response time?\n2. How do you find the slowest transactions?\n3. What does high wait time mean?\n4. What does high database time mean?\n5. How do you find an expensive statement?\n6. What are buffer swaps?\n7. How do you check for memory bottlenecks?\n8. How do you approach the complaint that the system is slow?\n\n## HANA (INT-012)\n\n1. Explain column store and row store\n2. What are savepoints and the redo log?\n3. Which services does HANA run?\n4. How do you start and stop HANA and a tenant?\n5. How do you back up and recover HANA?\n6. What is point-in-time recovery and what does it need?\n7. How do you analyse memory problems?\n8. How do you find blocking transactions?\n\n## S/4HANA (INT-013)\n\n1. What changes for Basis with S/4HANA?\n2. What is the difference between embedded and hub Fiori deployment?\n3. How do you activate a Fiori app?\n4. How do you troubleshoot an OData error?\n5. What does the web dispatcher do in an S/4HANA landscape?\n6. What are the conversion paths to S/4HANA?\n7. What is a simplification item?\n8. What is the readiness check?\n\n## Security (INT-014)\n\n1. What are the user types?\n2. How do you secure the standard users?\n3. What is the security audit log?\n4. How do you secure RFC destinations?\n5. What are the gateway access control lists?\n6. What is SNC?\n7. How do you replace an expiring certificate?\n8. What is segregation of duties in Basis operations?\n\n## HA/DR (INT-015)\n\n1. What are the single points of failure of an SAP system?\n2. How does enqueue replication work?\n3. What is fencing and why is it needed?\n4. Explain HANA system replication modes and operation modes\n5. What happens at takeover and how do clients reconnect?\n6. What are recovery point and recovery time objectives?\n7. How do you test high availability?\n8. How do you run a DR drill?\n\n## Upgrade (INT-016)\n\n1. What are the phases of an upgrade?\n2. What is the shadow system?\n3. What is the stack file?\n4. What are the dictionary and repository adjustments?\n5. How do you estimate downtime?\n6. What is your fallback plan?\n7. What do you validate after an upgrade?\n8. When do you use the support package manager and when the update manager?\n\n## Migration (INT-017)\n\n1. What is the difference between homogeneous and heterogeneous copy?\n2. What is the database migration option?\n3. How do you validate a migration?\n4. What drives migration downtime?\n5. What are the steps of a system refresh?\n6. What must be changed after a system copy?\n7. What is logical system conversion?\n8. How do you protect production data in a copied system?\n\n## Production Support (INT-018)\n\n1. How do you prioritise incidents?\n2. Describe a critical incident you handled\n3. What is in a root cause analysis?\n4. What is the difference between incident, problem and change?\n5. How do you hand over a shift?\n6. How do you plan patching for a landscape?\n7. How do you handle an emergency change?\n8. What is in your operations handbook?\n\n## Scenario-Based (INT-019)\n\n1. Users report that the system is slow: what do you do?\n2. Nobody can log on: what do you check and in which order?\n3. An import ended with return code 8 in production: what now?\n4. The log volume of HANA is full: what do you do?\n5. A certificate expires tomorrow: what is your plan?\n6. After a refresh, production partners receive test messages: what went wrong?\n7. The cluster did not fail over: how do you analyse it?\n8. A kernel patch must be applied with minimal downtime: how?\n\n## Architect-Level (INT-020)\n\n1. How do you size an S/4HANA landscape?\n2. How do you design HA and DR for given objectives?\n3. How do you decide between on-premise, hyperscaler and managed private cloud?\n4. How do you design the network zones of an SAP landscape?\n5. How do you plan a conversion to S/4HANA?\n6. What would you automate first and why?\n7. How do you design monitoring for a large landscape?\n8. How do you document and defend an architecture decision?\n",
   "parent": "Wiki"
  },
  {
   "title": "Documentation_Set",
   "text": "# Documentation set\n\nEvery learner builds and maintains these documents; they are finalised in module 58.\n\n| Document | First written in |\n|---|---|\n| SAP landscape document | Module 08, capstone |\n| Architecture diagram | Module 07 |\n| Server inventory | Module 01 |\n| Port matrix | Module 04 |\n| Filesystem document | Module 02 |\n| SAP instance document | Modules 08 and 13 |\n| HANA architecture document | Modules 30 to 32 |\n| Backup policy | Module 50 |\n| DR document | Modules 37 and 51 |\n| HA document | Modules 36 and 49 |\n| Monitoring document | Modules 26 and 54 |\n| Security document | Module 42 |\n| Transport document | Module 23 |\n| Upgrade document | Module 47 |\n| Migration document | Module 48 |\n| Daily health-check document | Module 57 |\n| Troubleshooting runbook | Module 56 |\n| RCA document | Modules 55 to 57 |\n| Production support runbook | Module 57 |",
   "parent": "Wiki"
  },
  {
   "title": "Workflow_and_Statuses",
   "text": "# Workflow and statuses\n\n| Status | Meaning | Course workflow stage |\n|---|---|---|\n| New | Template or unassigned | New |\n| Assigned | Belongs to a student, not started | Lab Pending |\n| In Progress | Being worked on | Learning / Lab In Progress |\n| Blocked | Cannot continue; a note states the blocker | Troubleshooting |\n| Testing | Steps done; student validates the expected result and collects evidence | Testing |\n| Review | Submitted to the instructor | Evidence Submitted |\n| Completed | Approved by the instructor | Reviewed / Completed |\n| Reopened | Changes requested | - |\n| Rejected | Waived or not applicable (instructor only) | - |\n\nThe statuses are shared with the other training projects on this Redmine. Prerequisites are *blocked by* relations: an issue cannot be closed while its blocker is open.\n\nEstimated Hours and Actual Hours are Redmine's estimated time and spent time.",
   "parent": "Wiki"
  },
  {
   "title": "Assessment_and_Grading",
   "text": "# Assessment and grading\n\n| Assessment | Covers |\n|---|---|\n| Level 1 | Linux, networking, databases, SAP fundamentals |\n| Level 2 | Basis administration, users, jobs, transports, monitoring, troubleshooting |\n| Level 3 | HANA, S/4HANA, Fiori, security, HA/DR |\n| Level 4 | Architecture, migration, upgrade, automation, cloud, production support |\n| Projects and capstone | Each scored 0-100 |\n\nPass mark 70, recorded in the Assessment Score field. Programme grade: assessments 25 %, projects 25 %, incidents and RCAs 20 %, capstone 30 %.",
   "parent": "Wiki"
  },
  {
   "title": "Completion_Criteria",
   "text": "# Completion criteria\n\nA learner is not complete because the theory was read. Completion requires demonstrated work in:\n\n- Linux administration\n- Networking fundamentals\n- SAP architecture\n- SAP installation\n- SAP administration\n- SAP monitoring\n- User administration\n- Job administration\n- Transport management\n- RFC administration\n- Gateway administration\n- Web Dispatcher\n- Security fundamentals\n- HANA administration\n- HANA backup/recovery\n- HANA HA/DR\n- S/4HANA administration\n- Fiori administration\n- System copy\n- System refresh\n- Upgrade\n- Migration concepts\n- HA\n- DR\n- Cloud concepts\n- Automation\n- Monitoring/observability\n- Production support\n- Troubleshooting\n- RCA\n- Real-world projects\n- Final enterprise capstone\n\nIn Redmine: all 59 gate reviews are Completed.",
   "parent": "Wiki"
  },
  {
   "title": "Dashboard_Guide",
   "text": "# Dashboard guide\n\nThe dashboard is the set of saved queries in the issue list sidebar. Add them to *My page* as custom query blocks.\n\n| Dashboard item | Saved query |\n|---|---|\n| Overall completion % | Dashboard: overall completion |\n| Level completion | Dashboard: level completion |\n| Module completion | Dashboard: module completion |\n| Lab completion | Dashboard: lab completion |\n| HANA progress | Dashboard: HANA progress |\n| S/4HANA progress | Dashboard: S/4HANA progress |\n| Security progress | Dashboard: security progress |\n| HA/DR progress | Dashboard: HA/DR progress |\n| Automation progress | Dashboard: automation progress |\n| Assessment score | Dashboard: assessment scores |\n| Open incidents | Dashboard: open incidents |\n| RCA completion | Dashboard: RCA completion |\n| Project completion | Dashboard: project completion |\n| Capstone progress | Dashboard: capstone progress |\n| Interview readiness | Dashboard: interview readiness |\n\nFor % done to follow the status, set *Administration > Settings > Issue tracking > Calculate the issue done ratio* to *Use the issue status* (global setting).",
   "parent": "Wiki"
  },
  {
   "title": "Tool_Index",
   "text": "# Tool index\n\nWhere each transaction, command and view is used. The six-part transaction reference and the five-part command reference are written by the student in modules 02 and 29.\n\n## SAP transactions and reports\n\n| Tool | Modules |\n|---|---|\n| /IWBEP/ERROR_LOG | 41 |\n| /IWFND/CACHE_CLEANUP | 41 |\n| /IWFND/ERROR_LOG | 40, 41 |\n| /IWFND/GW_CLIENT | 41 |\n| /IWFND/MAINT_SERVICE | 40, 41 |\n| /UI2/FLIA | 40 |\n| /UI2/FLP | 39, 40 |\n| /UI2/FLPCM_CUST | 40 |\n| /UI2/FLPD_CUST | 40 |\n| /UI5/APP_INDEX_CALCULATE | 40 |\n| AL08 | 13, 26, 29 |\n| ATC | 48 |\n| BDLS | 44, 45 |\n| BTCTRNS1 | 44 |\n| BTCTRNS2 | 44 |\n| DBACOCKPIT | 26, 28, 29, 38, 39, 55, 57 |\n| PFCG | 14, 40 |\n| RSAU_CONFIG | 42 |\n| RSAU_READ_LOG | 42 |\n| RSPO1041 | 16 |\n| RSPO1043 | 16 |\n| RSUSR003 | 14, 42 |\n| RZ04 | 13 |\n| RZ10 | 08, 12, 21, 29, 42 |\n| RZ11 | 12, 21, 29 |\n| RZ12 | 19, 20 |\n| SA38 | 29 |\n| SAINT | 25, 47 |\n| SAT | 28 |\n| SBGRFCMON | 19 |\n| SCC1 | 23 |\n| SCC3 | 29 |\n| SCC4 | 08, 24, 29, 44 |\n| SCC7 | 45 |\n| SCC8 | 45 |\n| SCCL | 29 |\n| SE01 | 23 |\n| SE03 | 23, 24 |\n| SE06 | 08, 23, 24, 29, 44, 45 |\n| SE09 | 23 |\n| SE10 | 23, 24 |\n| SE11 | 29 |\n| SE16 | 29 |\n| SE38 | 15, 29 |\n| SE80 | 29 |\n| SE93 | 29 |\n| SE95 | 25 |\n| SECPOL | 14 |\n| SECSTORE | 44 |\n| SFW5 | 29, 39 |\n| SGEN | 08, 29, 47 |\n| SICF | 21, 39, 40, 41 |\n| SICK | 08, 47 |\n| SLAW2 | 46 |\n| SLICENSE | 08, 44, 46, 57 |\n| SM01 | 29 |\n| SM04 | 13, 17, 29 |\n| SM12 | 07, 17, 26, 29, 49, 55, 57 |\n| SM13 | 17, 18, 26, 29, 55, 57 |\n| SM14 | 18 |\n| SM19 | 42 |\n| SM20 | 14, 42 |\n| SM21 | 08, 18, 26, 27, 29, 44, 55, 56, 57 |\n| SM28 | 08 |\n| SM36 | 08, 15, 29 |\n| SM37 | 15, 26, 29, 44, 45, 55, 57 |\n| SM50 | 07, 13, 15, 17, 18, 26, 27, 28, 29, 55, 56, 57 |\n| SM51 | 07, 10, 11, 13, 20, 29, 39, 57 |\n| SM58 | 19, 26, 45, 57 |\n| SM59 | 19, 29, 41, 42, 43, 44, 45, 51, 57 |\n| SM61 | 15 |\n| SM62 | 15 |\n| SM63 | 13 |\n| SM64 | 15 |\n| SM65 | 15 |\n| SM66 | 13, 26, 28, 29 |\n| SMGW | 07, 19, 27, 29, 42 |\n| SMICM | 07, 21, 22, 26, 27, 29, 39, 43 |\n| SMLG | 20, 29, 51 |\n| SMMS | 07, 20, 29 |\n| SMQ1 | 19, 45 |\n| SMQ2 | 19 |\n| SNC0 | 42 |\n| SNOTE | 25, 29 |\n| SP01 | 16, 26, 29, 57 |\n| SP12 | 16 |\n| SPAD | 16, 29, 44, 45 |\n| SPAM | 25, 47 |\n| SPAU | 25, 47, 48 |\n| SPDD | 25, 47, 48 |\n| SSFA | 43 |\n| ST01 | 42 |\n| ST02 | 12, 28, 29 |\n| ST03N | 26, 28, 29, 57 |\n| ST04 | 28 |\n| ST05 | 28 |\n| ST06 | 26, 28, 29, 57 |\n| ST11 | 27 |\n| ST12 | 28 |\n| ST22 | 18, 19, 26, 27, 29, 55, 56, 57 |\n| STAD | 28 |\n| STAUTHTRACE | 42 |\n| STC01 | 40 |\n| STMS | 08, 23, 24, 29, 44, 45, 57, 59 |\n| STRUST | 21, 29, 42, 43, 57, 59 |\n| SU01 | 08, 14, 19, 42, 45 |\n| SU10 | 14 |\n| SU3 | 14 |\n| SU53 | 14, 41 |\n| SU56 | 14 |\n| SUGR | 14 |\n| SUIM | 14 |\n| TU02 | 12 |\n| USMM | 46 |\n| WE20 | 45 |\n\n## Commands and tools\n\n| Tool | Modules |\n|---|---|\n| alertmanager | 54 |\n| ansible | 53 |\n| ansible-playbook | 53, 59 |\n| awk | 02, 03 |\n| bash | 03, 53 |\n| cat | 02 |\n| cd | 02 |\n| corosync | 49 |\n| cp | 02 |\n| crm | 49, 59 |\n| cron | 03 |\n| curl | 02, 04 |\n| df | 02, 56 |\n| dig | 02, 04 |\n| disp+work | 10 |\n| dpmon | 13, 56 |\n| du | 02 |\n| ensmon | 17 |\n| find | 02 |\n| free | 02 |\n| grafana | 54 |\n| grep | 02 |\n| gzip | 02 |\n| HDB | 11, 30, 31, 32, 36, 56 |\n| hdbbackupcheck | 34 |\n| hdbbackupdiag | 34 |\n| hdblcm | 08, 31, 59 |\n| hdbnsutil | 32, 36, 37, 49, 51, 59 |\n| hdbsql | 30, 31, 32, 33, 34, 35, 37, 38, 46, 50, 56 |\n| hdbuserstore | 31, 33 |\n| htop | 02 |\n| iostat | 28 |\n| ip | 02 |\n| journalctl | 02, 27, 56 |\n| less | 02 |\n| lgtst | 20 |\n| lpstat | 16 |\n| ls | 02 |\n| lsblk | 02 |\n| mount | 02 |\n| mv | 02 |\n| nc | 04 |\n| netstat | 04 |\n| niping | 04 |\n| node_exporter | 54 |\n| nslookup | 02, 04 |\n| openssl | 43 |\n| pcs | 49 |\n| ping | 02, 04 |\n| prometheus | 54 |\n| promtool | 54 |\n| ps | 02 |\n| python3 | 53 |\n| R3load | 48 |\n| R3trans | 23 |\n| recoverSys.py | 35 |\n| rm | 02 |\n| rsync | 02, 50 |\n| SAPCAR | 08, 10 |\n| sapcontrol | 04, 07, 09, 10, 11, 22, 32, 49, 50, 51, 53, 54, 56, 59 |\n| sapgenpse | 43 |\n| SAPHanaSR-showAttr | 49 |\n| saphostctrl | 09 |\n| saphostexec | 09 |\n| sapinst | 08, 59 |\n| saplikey | 46 |\n| sappfpar | 12 |\n| saprouter | 04 |\n| sapstartsrv | 09 |\n| sapwebdisp | 22 |\n| sar | 28 |\n| scp | 02 |\n| sed | 02, 03 |\n| SQL | 05 |\n| ss | 02, 04, 56 |\n| ssh | 02 |\n| startsap | 11 |\n| stopsap | 11 |\n| SUM | 25, 47, 48 |\n| SWPM | 08, 44, 48 |\n| systemctl | 02, 11 |\n| systemReplicationStatus.py | 36 |\n| tail | 02 |\n| tar | 02, 50 |\n| tcpdump | 04 |\n| terraform | 53 |\n| top | 02, 56 |\n| tp | 23 |\n| traceroute | 02, 04 |\n| vmstat | 28 |\n| wdispmon | 22 |\n| wget | 02 |\n| Wireshark | 04 |\n\n## HANA system views\n\n| Tool | Modules |\n|---|---|\n| AUDIT_LOG | 33 |\n| M_BACKUP_CATALOG | 34, 35 |\n| M_BLOCKED_TRANSACTIONS | 38 |\n| M_CS_TABLES | 38 |\n| M_DELTA_MERGE_STATISTICS | 38 |\n| M_EXPENSIVE_STATEMENTS | 38 |\n| M_PASSWORD_POLICY | 33 |\n| M_SERVICE_REPLICATION | 36 |\n| M_SERVICE_THREADS | 38 |\n| M_SERVICES | 30, 32 |\n| M_SQL_PLAN_CACHE | 38 |\n| M_SYSTEM_OVERVIEW | 32 |\n",
   "parent": "Wiki"
  },
  {
   "title": "Module_Index",
   "text": "# Module index\n\n## Module 01 - IT Foundation (V01 - IT Foundation)\n\n### Computer and Server Fundamentals\n\nTopics: CPU; RAM; Storage; SSD/NVMe; Filesystems; Processes; Services; Ports; IP addresses; DNS; Routing; Firewalls; Load balancers; Virtualization; Hypervisors; Virtual machines; Containers; Data centers; Cloud infrastructure; How SAP depends on infrastructure\n\n- THY-001 Server hardware: CPU, RAM and storage (Theory, 3 h)\n- THY-002 Operating system basics: processes, services, ports and addresses (Theory, 3 h)\n- THY-003 Virtualization, containers, data centres and cloud (Theory, 3 h)\n- THY-004 How SAP depends on infrastructure (Theory, 2 h)\n- ASG-001 Infrastructure inventory of the training landscape (Assignment, 2 h)\n\n## Module 02 - Linux Administration (V02 - Linux & Networking)\n\n### Linux System Basics\n\nTopics: Linux architecture; Filesystem; Users; Groups; Permissions; sudo; Package management; Environment variables\n\n- THY-005 Linux architecture and the filesystem hierarchy (Theory, 3 h)\n- BASIS-LAB-001 Install the Linux lab server (Installation Lab, 4 h)\n- BASIS-LAB-002 Files, directories, search and text tools (Administration Lab, 3 h)\n- BASIS-LAB-003 Users, groups, permissions and sudo (Administration Lab, 3 h)\n- BASIS-LAB-004 Package management and repositories (Administration Lab, 2 h)\n- BASIS-LAB-005 Environment variables and the shell profile (Administration Lab, 2 h)\n\n### Linux Services, Storage and Networking\n\nTopics: Processes; systemd; Services; Networking; DNS; SSH; Storage; LVM; Mounts; Filesystems; NFS; Logs; Cron; Kernel parameters; Resource management\n\n- BASIS-LAB-006 Processes, systemd and services (Administration Lab, 3 h)\n- BASIS-LAB-007 Logs, journal and cron (Administration Lab, 2 h)\n- BASIS-LAB-008 Storage: disks, LVM, filesystems and mounts (Administration Lab, 4 h)\n- BASIS-LAB-009 NFS for shared SAP directories (Administration Lab, 2 h)\n- BASIS-LAB-010 Networking, DNS and SSH on Linux (Administration Lab, 3 h)\n- BASIS-LAB-011 Kernel parameters, limits, swap and SAP tuning tools (Administration Lab, 3 h)\n- ASG-002 Command reference part 1: files and text (Assignment, 3 h)\n- ASG-003 Command reference part 2: system and storage (Assignment, 3 h)\n- ASG-004 Command reference part 3: network and transfer (Assignment, 3 h)\n- INC-001 Incident 001: Disk full on a system filesystem (Troubleshooting Incident, 1 h)\n- INC-002 Incident 002: Filesystem mounted read-only (Troubleshooting Incident, 1 h)\n- INC-003 Incident 003: NFS share unavailable and processes hang (Troubleshooting Incident, 1 h)\n- INC-004 Incident 004: SSH login fails for the administrator user (Troubleshooting Incident, 1 h)\n- INC-005 Incident 005: Service does not start after reboot (Troubleshooting Incident, 1 h)\n\n## Module 03 - Linux Shell Scripting (V02 - Linux & Networking)\n\n### Shell Scripting for Basis\n\nTopics: Bash; Variables; Conditions; Loops; Functions; Exit codes; Logging; Error handling; Scheduling; Monitoring scripts; Backup scripts; SAP health-check scripts\n\n- THY-006 Bash scripting fundamentals (Theory, 3 h)\n- BASIS-LAB-012 First scripts: arguments, conditions, loops and functions (Administration Lab, 3 h)\n- BASIS-LAB-013 Script: filesystem monitoring and disk-space alerts (Administration Lab, 3 h)\n- BASIS-LAB-014 Script: process monitoring (Administration Lab, 2 h)\n- BASIS-LAB-015 Script: log monitoring (Administration Lab, 3 h)\n- BASIS-LAB-016 Script: backup validation (Administration Lab, 2 h)\n- BASIS-LAB-017 Scripts: SAP instance status and HANA service status against sample output (Administration Lab, 3 h)\n- ASG-005 Scheduling, locking and housekeeping for scripts (Assignment, 2 h)\n\n## Module 04 - Networking (V02 - Linux & Networking)\n\n### Networking Fundamentals\n\nTopics: OSI model; TCP/IP; IPv4; IPv6 concepts; Subnetting; Routing; VLAN concepts; DNS; DHCP; TCP; UDP; Ports; NAT; Firewall; Proxy; Load balancing; Reverse proxy; TLS/SSL; Certificates\n\n- THY-007 OSI, TCP/IP, addressing and subnetting (Theory, 3 h)\n- THY-008 TCP, UDP, ports, firewalls, proxies and load balancers (Theory, 3 h)\n- BASIS-LAB-018 Network troubleshooting tools (Administration Lab, 4 h)\n- BASIS-LAB-019 Host firewall (Administration Lab, 2 h)\n\n### SAP Networking\n\nTopics: SAP dispatcher communication; SAP message server; SAP gateway; HTTP/HTTPS; RFC; SAProuter; Database connectivity; HANA communication; SAP Web Dispatcher\n\n- THY-009 SAP ports and communication paths (Theory, 3 h)\n- THY-010 SAProuter and network zones (Theory, 2 h)\n- ASG-006 Port matrix for the lab landscape (Assignment, 3 h)\n- INC-006 Incident 006: DNS failure: host name does not resolve (Troubleshooting Incident, 1 h)\n- INC-007 Incident 007: Port blocked between two servers (Troubleshooting Incident, 1 h)\n- PROJECT-001 Project 1: Linux SAP Server Preparation (Project, 6 h)\n\n## Module 05 - Database Fundamentals (V01 - IT Foundation)\n\n### Database Fundamentals\n\nTopics: Relational databases; SQL basics; Tables; Indexes; Transactions; Locks; Sessions; Connections; Backup; Recovery; Replication; HA; Performance; SAP HANA; SAP ASE concepts; SQL Server concepts; Oracle concepts; MaxDB concepts\n\n- THY-011 Relational databases and SQL (Theory, 3 h)\n- BASIS-LAB-020 SQL basics for administrators (Administration Lab, 3 h)\n- THY-012 Backup, recovery, replication, availability and performance concepts (Theory, 3 h)\n- THY-013 Databases under SAP: HANA, ASE, SQL Server, Oracle and MaxDB (Theory, 2 h)\n\n## Module 06 - SAP Fundamentals (V03 - SAP Foundation)\n\n### SAP Fundamentals\n\nTopics: What is SAP; ERP; SAP ECC; SAP S/4HANA; SAP Business Suite; SAP modules; FI; CO; MM; SD; PP; QM; PM; HCM; Basis; ABAP; Functional vs technical SAP\n\n- THY-014 ERP, SAP products and the modules (Theory, 3 h)\n- THY-015 Functional versus technical SAP and the Basis role (Theory, 2 h)\n- ASG-007 Glossary of SAP technical terms (Assignment, 2 h)\n\n## Module 07 - SAP Architecture (V03 - SAP Foundation)\n\n### SAP Three-Tier Architecture\n\nTopics: Presentation layer; Application layer; Database layer; Dispatcher; Work processes; Message Server; Enqueue Server; Gateway; ICM; Database; Central Services; ASCS; ERS; Flow: users, SAP GUI or Fiori, Web Dispatcher, application servers, database\n\n- THY-016 The three layers and the path of a request (Theory, 3 h)\n- THY-017 Components of the application layer (Theory, 4 h)\n\n### SAP Instance Architecture\n\nTopics: SAP system; SID; Instance; System number; Instance number; Hostname; Profile; Kernel; Executables; Work directories; ASCS; PAS; AAS; ERS; HANA database\n\n- THY-018 System, instance, SID and numbers (Theory, 3 h)\n- THY-019 ASCS, PAS, AAS, ERS and the database instance (Theory, 3 h)\n- BASIS-LAB-021 Explore a running SAP system (Administration Lab, 3 h)\n- ASG-008 Architecture diagrams of the lab landscape (Assignment, 3 h)\n- ASM-001 Level 1 assessment: Linux, networking, databases and SAP fundamentals (Assessment, 3 h)\n\n## Module 08 - SAP Installation (V04 - Core Basis)\n\n### SAP Installation Lifecycle\n\nTopics: Infrastructure preparation; OS preparation; Filesystem planning; Hostname; DNS; SAP users; Kernel; Installation media; SAP Host Agent; SWPM; SAP installation; Database installation; Post-installation configuration; SAP NetWeaver; SAP S/4HANA; SAP HANA\n\n- THY-020 The installation lifecycle and its documents (Theory, 3 h)\n- THY-021 NetWeaver, ABAP platform and S/4HANA installations compared (Theory, 2 h)\n- BASIS-LAB-022 Prepare installation media and check prerequisites (Installation Lab, 3 h)\n- BASIS-LAB-023 Install the SAP HANA database for the system (guided) (Installation Lab, 4 h)\n- BASIS-LAB-024 Install ASCS, database instance and primary application server (Installation Lab, 6 h)\n- BASIS-LAB-025 Post-installation configuration (Administration Lab, 5 h)\n- BASIS-LAB-026 Install an additional application server (Installation Lab, 3 h)\n- INC-008 Incident 008: Installer aborts in the prerequisite or database load phase (Troubleshooting Incident, 1 h)\n- INC-009 Incident 009: Installation fails on host name resolution (Troubleshooting Incident, 1 h)\n- PROJECT-002 Project 2: SAP Installation (Project, 8 h)\n\n## Module 09 - SAP Host Agent (V04 - Core Basis)\n\n### SAP Host Agent\n\nTopics: SAP Host Agent; Architecture; Installation; Configuration; Monitoring; Troubleshooting; Security; sapstartsrv; Chain: SAP Host Agent, sapstartsrv, SAP instance\n\n- THY-022 Host agent and sapstartsrv (Theory, 3 h)\n- BASIS-LAB-027 Install, upgrade and operate the host agent (Administration Lab, 3 h)\n- BASIS-LAB-028 sapstartsrv and its web service interface (Administration Lab, 2 h)\n- INC-010 Incident 010: sapstartsrv not responding: sapcontrol returns a connection error (Troubleshooting Incident, 1 h)\n\n## Module 10 - SAP Kernel (V04 - Core Basis)\n\n### SAP Kernel\n\nTopics: SAP Kernel; Kernel files; Kernel versions; Kernel patches; Kernel upgrade; Kernel compatibility; Kernel rollback; Kernel troubleshooting\n\n- THY-023 What the kernel is and how it is maintained (Theory, 3 h)\n- BASIS-LAB-029 Kernel patch (Administration Lab, 4 h)\n- BASIS-LAB-030 Kernel rollback (Administration Lab, 2 h)\n- INC-011 Incident 011: Kernel mismatch: instance does not start after a kernel change (Troubleshooting Incident, 1 h)\n\n## Module 11 - SAP Start Stop (V04 - Core Basis)\n\n### Starting and Stopping SAP\n\nTopics: sapcontrol; startsap concepts; stopsap concepts; systemd integration; sapstartsrv; Instance startup sequence; Shutdown sequence\n\n- THY-024 Startup and shutdown sequences (Theory, 3 h)\n- BASIS-LAB-031 Start, stop and restart with sapcontrol (Administration Lab, 3 h)\n- BASIS-LAB-032 Follow a startup in the traces (Administration Lab, 2 h)\n- INC-012 Incident 012: Instance won't start: database not reachable (Troubleshooting Incident, 1 h)\n- INC-013 Incident 013: Instance won't start: port already in use or leftover processes (Troubleshooting Incident, 1 h)\n- INC-014 Incident 014: Instance won't start: profile or directory problem (Troubleshooting Incident, 1 h)\n\n## Module 12 - SAP Profiles (V04 - Core Basis)\n\n### SAP Profiles and Parameters\n\nTopics: Default profile; Instance profile; Start profile; Profile parameters; Dynamic parameters; Static parameters; Parameter changes; RZ10; RZ11; Profile backup; Parameter validation; Chain: parameter, memory, work process, performance\n\n- THY-025 Profiles and how parameters take effect (Theory, 3 h)\n- THY-026 From parameter to memory to work process to performance (Theory, 3 h)\n- BASIS-LAB-033 Display, change and validate parameters (Administration Lab, 3 h)\n- INC-015 Incident 015: Instance does not start after a parameter change (Troubleshooting Incident, 1 h)\n\n## Module 13 - Work Processes (V04 - Core Basis)\n\n### SAP Work Processes\n\nTopics: Dialog; Background; Update; Spool; Enqueue; Work process architecture; Dispatcher; Request queues; Process states; Flow: user request, dispatcher, work process, database, response\n\n- THY-027 Work process types and the dispatcher (Theory, 3 h)\n- BASIS-LAB-034 Monitor work processes and users (Administration Lab, 3 h)\n- BASIS-LAB-035 Operation modes (Administration Lab, 2 h)\n- BASIS-LAB-036 Long-running dialog, work process exhaustion and background congestion in the lab (Administration Lab, 3 h)\n- INC-016 Incident 016: Work process exhaustion: all dialog processes occupied (Troubleshooting Incident, 1 h)\n- INC-017 Incident 017: Long-running dialog process in PRIV mode (Troubleshooting Incident, 1 h)\n- PROJECT-003 Project 3: SAP Start/Stop and Instance Administration (Project, 5 h)\n\n## Module 14 - User Administration (V04 - Core Basis)\n\n### SAP Users and Authorization\n\nTopics: User creation; User types; Password policy; Lock/unlock; User validity; Roles; Profiles; Authorization objects; Composite roles; Single roles; Generated profiles; SU01; PFCG; SU10; SUIM; Collaboration with SAP Security\n\n- THY-028 Users, user types and password rules (Theory, 3 h)\n- THY-029 The authorization concept (Theory, 3 h)\n- BASIS-LAB-037 Create and maintain users (Administration Lab, 3 h)\n- BASIS-LAB-038 Build and assign a role (Administration Lab, 4 h)\n- BASIS-LAB-039 User information system and password policy (Administration Lab, 2 h)\n- INC-018 Incident 018: User locked after failed logons and cannot work (Troubleshooting Incident, 1 h)\n- INC-019 Incident 019: Authorization issue: transaction fails for a user after a role change (Troubleshooting Incident, 1 h)\n- PROJECT-004 Project 4: SAP User Administration (Project, 4 h)\n\n## Module 15 - Background Jobs (V04 - Core Basis)\n\n### SAP Job Management\n\nTopics: Background jobs; Job scheduling; Job classes; Job steps; Variants; Job logs; Job cancellation; Job monitoring; Periodic jobs; Event-based jobs\n\n- THY-030 Background processing (Theory, 3 h)\n- BASIS-LAB-040 Schedule and monitor jobs (Administration Lab, 3 h)\n- BASIS-LAB-041 Event-based jobs and job dependencies (Administration Lab, 2 h)\n- BASIS-LAB-042 Housekeeping jobs and background system check (Administration Lab, 2 h)\n- INC-020 Incident 020: Job cancelled: missing variant (Troubleshooting Incident, 1 h)\n- INC-021 Incident 021: Job delayed: no free background work process (Troubleshooting Incident, 1 h)\n- INC-022 Incident 022: Job running too long (Troubleshooting Incident, 1 h)\n- INC-023 Incident 023: Job fails with an authorization error (Troubleshooting Incident, 1 h)\n- PROJECT-005 Project 5: Background Job Management (Project, 4 h)\n\n## Module 16 - Spool (V04 - Core Basis)\n\n### SAP Spool and Printing\n\nTopics: Spool architecture; Spool requests; Output requests; Printers; Device types; Access methods; Print servers; SAP printing; Troubleshooting\n\n- THY-031 Spool architecture (Theory, 2 h)\n- BASIS-LAB-043 Define output devices and print (Administration Lab, 3 h)\n- BASIS-LAB-044 Spool administration and housekeeping (Administration Lab, 2 h)\n- BASIS-LAB-045 Printer troubleshooting lab (Administration Lab, 2 h)\n- INC-024 Incident 024: Spool issue: output requests stay in status waiting (Troubleshooting Incident, 1 h)\n- INC-025 Incident 025: Spool overflow: no more spool requests can be created (Troubleshooting Incident, 1 h)\n\n## Module 17 - Locks (V04 - Core Basis)\n\n### SAP Lock Management\n\nTopics: Enqueue; Lock objects; Lock entries; Lock server; SM12; Lock conflicts; Stale locks; Enqueue replication; Chain: business transaction, lock, database consistency\n\n- THY-032 The SAP lock concept (Theory, 3 h)\n- BASIS-LAB-046 Analyse lock entries (Administration Lab, 3 h)\n- INC-026 Incident 026: Lock issue: old lock entries remain after a user's session ended (Troubleshooting Incident, 1 h)\n- INC-027 Incident 027: Lock table overflow (Troubleshooting Incident, 1 h)\n\n## Module 18 - Update Management (V04 - Core Basis)\n\n### SAP Update Management\n\nTopics: Update process; V1 updates; V2 updates; Update requests; Failed updates; SM13; Update work processes\n\n- THY-033 The update system (Theory, 2 h)\n- BASIS-LAB-047 Monitor and handle update requests (Administration Lab, 3 h)\n- INC-028 Incident 028: Update terminated for many users after a transport (Troubleshooting Incident, 1 h)\n- INC-029 Incident 029: Update backlog: update deactivated after a database error (Troubleshooting Incident, 1 h)\n\n## Module 19 - RFC & Gateway (V04 - Core Basis)\n\n### SAP RFC and Gateway\n\nTopics: RFC; RFC destinations; Synchronous RFC; Asynchronous RFC; Background RFC; Transactional RFC; Queued RFC; RFC security; Gateway; SM59; SMGW\n\n- THY-034 RFC types and the gateway (Theory, 3 h)\n- THY-035 RFC security (Theory, 2 h)\n- BASIS-LAB-048 Create and test RFC destinations (Administration Lab, 3 h)\n- BASIS-LAB-049 Monitor asynchronous RFC and the gateway (Administration Lab, 3 h)\n- BASIS-LAB-050 Integration troubleshooting lab (Administration Lab, 3 h)\n- INC-030 Incident 030: RFC failure: destination returns logon error (Troubleshooting Incident, 1 h)\n- INC-031 Incident 031: Gateway failure: registered program cannot register (Troubleshooting Incident, 1 h)\n- INC-032 Incident 032: Transactional RFC entries pile up (Troubleshooting Incident, 1 h)\n\n## Module 20 - Message Server (V04 - Core Basis)\n\n### SAP Message Server and Logon Load Balancing\n\nTopics: Message Server; Communication; Logon groups; Load balancing; SMLG; SMMS; Flow: users, message server, logon group, application server\n\n- THY-036 Message server and load balancing (Theory, 2 h)\n- BASIS-LAB-051 Logon groups (Administration Lab, 3 h)\n- INC-033 Incident 033: Message server failure: group logon fails while direct logon works (Troubleshooting Incident, 1 h)\n\n## Module 21 - ICM (V04 - Core Basis)\n\n### SAP Internet Communication Manager\n\nTopics: Internet Communication Manager; HTTP; HTTPS; Ports; Services; ICM parameters; SMICM; ICM traces; TLS\n\n- THY-037 ICM architecture (Theory, 2 h)\n- BASIS-LAB-052 Configure HTTP and HTTPS and activate services (Administration Lab, 4 h)\n- BASIS-LAB-053 ICM monitoring, traces and restart (Administration Lab, 2 h)\n- INC-034 Incident 034: HTTP failure: service returns forbidden or not found (Troubleshooting Incident, 1 h)\n- INC-035 Incident 035: HTTPS failure: handshake error in the browser (Troubleshooting Incident, 1 h)\n- INC-036 Incident 036: Port unavailable: the manager cannot bind its port (Troubleshooting Incident, 1 h)\n\n## Module 22 - Web Dispatcher (V04 - Core Basis)\n\n### SAP Web Dispatcher\n\nTopics: SAP Web Dispatcher; Reverse proxy; Load balancing; Routing; SSL termination; URL filtering; Backend connection; Configuration; Monitoring; Troubleshooting\n\n- THY-038 Web dispatcher architecture (Theory, 3 h)\n- BASIS-LAB-054 Install and configure a web dispatcher (Installation Lab, 4 h)\n- BASIS-LAB-055 TLS termination, URL filtering and monitoring (Administration Lab, 3 h)\n- INC-037 Incident 037: Web Dispatcher failure: 503 no server available (Troubleshooting Incident, 1 h)\n- INC-038 Incident 038: Web Dispatcher returns a certificate error only for external users (Troubleshooting Incident, 1 h)\n- PROJECT-006 Project 15: SAP Web Dispatcher (Project, 5 h)\n\n## Module 23 - Transport Management (V06 - Transport)\n\n### SAP Transport Management System\n\nTopics: Transport request; Workbench request; Customizing request; Transport routes; Transport domain; Domain controller; Import queue; Import process; Transport logs; Return codes; Transport errors; STMS; SE09; SE10; DEV to QAS to PRD landscape\n\n- THY-039 Change transport concepts (Theory, 3 h)\n- THY-040 Transport domain, routes and layers (Theory, 2 h)\n- BASIS-LAB-056 Configure the DEV to QAS to PRD landscape (Configuration, 4 h)\n- BASIS-LAB-057 Create, release and import requests (Administration Lab, 4 h)\n- BASIS-LAB-058 Return codes and transport logs (Administration Lab, 3 h)\n- BASIS-LAB-059 The transport programs on the host (Administration Lab, 2 h)\n- INC-039 Incident 039: Transport failure: import hangs and never ends (Troubleshooting Incident, 1 h)\n- INC-040 Incident 040: Transport failure: return code 8 on import (Troubleshooting Incident, 1 h)\n- INC-041 Incident 041: Transport failure: return code 12 or tool cannot connect (Troubleshooting Incident, 1 h)\n- INC-042 Incident 042: Import queue is empty although requests were released (Troubleshooting Incident, 1 h)\n- PROJECT-007 Project 6: Transport Management (Project, 5 h)\n\n## Module 24 - Change Management (V06 - Transport)\n\n### Change and Release Management\n\nTopics: Change requests; Transport lifecycle; Release management; Emergency changes; Production approvals; Transport sequencing; Dependency management; Rollback strategy; Audit trail\n\n- THY-041 Change and release management for SAP (Theory, 3 h)\n- CR-001 Change scenario: normal change through three systems (Change Request, 2 h)\n- CR-002 Change scenario: emergency change (Change Request, 2 h)\n- CR-003 Change scenario: dependency and sequence problem (Change Request, 2 h)\n- ASG-009 Release calendar and rollback plan (Assignment, 2 h)\n\n## Module 25 - SAP Notes & Patches (V06 - Transport)\n\n### SAP Notes and Support Packages\n\nTopics: SAP Notes; SNOTE; Note Assistant; Corrections; Support Packages; Support Package Stack; Maintenance Planner concepts; Software Update Manager; Compatibility; Testing\n\n- THY-042 Notes, corrections and the Note Assistant (Theory, 2 h)\n- THY-043 Support packages, stacks and the maintenance tools (Theory, 3 h)\n- BASIS-LAB-060 Implement and reset a note (Administration Lab, 3 h)\n- BASIS-LAB-061 Update the support package manager and import a package in the sandbox (Administration Lab, 4 h)\n- INC-043 Incident 043: SAP Note issue: note cannot be downloaded or implemented (Troubleshooting Incident, 1 h)\n- INC-044 Incident 044: Patch issue: support package import stops in a phase (Troubleshooting Incident, 1 h)\n\n## Module 26 - Monitoring (V05 - Monitoring)\n\n### SAP Monitoring\n\nTopics: Monitoring of SAP application, database, OS, CPU, memory, disk, network, work processes, jobs, dumps, locks, updates, RFC, spool, interfaces; ST06; ST03N; SM50; SM66; SM21; ST22; DBACOCKPIT; Solution Manager concepts; SAP Focused Run concepts; Prometheus/Grafana integration concepts\n\n- THY-044 What to monitor and why (Theory, 2 h)\n- BASIS-LAB-062 Monitor the application layer (Administration Lab, 3 h)\n- BASIS-LAB-063 Monitor operating system and database from SAP (Administration Lab, 3 h)\n- THY-045 Central monitoring: Solution Manager, Focused Run, Cloud ALM and open tools (Theory, 2 h)\n- PROJECT-008 Project 7: SAP Monitoring (Project, 5 h)\n\n## Module 27 - Logs & Traces (V05 - Monitoring)\n\n### SAP System Logs and Traces\n\nTopics: System log; Developer traces; Work process traces; Gateway traces; ICM traces; Dispatcher traces; HANA traces; Linux logs; Analysis: event, timestamp, component, error, trace, root cause, resolution\n\n- THY-046 Logs and traces of an SAP system (Theory, 3 h)\n- BASIS-LAB-064 Read the system log and developer traces (Administration Lab, 3 h)\n- BASIS-LAB-065 Log analysis exercise: three events end to end (Administration Lab, 4 h)\n- INC-045 Incident 045: Dispatcher failure: dispatcher trace shows the instance shutting down (Troubleshooting Incident, 1 h)\n- INC-046 Incident 046: Work processes restart repeatedly with errors in the trace (Troubleshooting Incident, 1 h)\n\n## Module 28 - Performance (V05 - Monitoring)\n\n### SAP Performance Management\n\nTopics: Application performance: dialog response time, work process utilization, CPU, memory, database time, wait time; Database performance: SQL, expensive statements, locks, connections, memory, CPU, disk; OS performance: CPU, RAM, swap, disk latency, I/O, network\n\n- THY-047 Response time and its components (Theory, 3 h)\n- BASIS-LAB-066 Workload analysis (Administration Lab, 3 h)\n- BASIS-LAB-067 Memory and buffers (Administration Lab, 2 h)\n- BASIS-LAB-068 Database performance from the application side (Administration Lab, 3 h)\n- BASIS-LAB-069 Operating system performance (Administration Lab, 3 h)\n- BASIS-LAB-070 Runtime analysis of a slow program (Administration Lab, 2 h)\n- INC-047 Incident 047: Performance degradation: high wait time for all users (Troubleshooting Incident, 1 h)\n- INC-048 Incident 048: Performance degradation: high database time (Troubleshooting Incident, 1 h)\n- INC-049 Incident 049: Performance degradation after a restart (Troubleshooting Incident, 1 h)\n- INC-050 Incident 050: CPU high on the application server host (Troubleshooting Incident, 1 h)\n- INC-051 Incident 051: Memory exhausted: host is swapping (Troubleshooting Incident, 1 h)\n- PROJECT-009 Project 8: SAP Performance Troubleshooting (Project, 5 h)\n\n## Module 29 - ABAP Administration (V04 - Core Basis)\n\n### SAP ABAP Administration\n\nTopics: ABAP runtime; Work processes; ABAP repository; Transport; Dumps; Background jobs; Program execution; Spool; RFC; Interfaces; ICM; ABAP troubleshooting at Basis level\n\n- THY-048 ABAP runtime and repository for administrators (Theory, 3 h)\n- BASIS-LAB-071 Short dump analysis (Administration Lab, 3 h)\n- BASIS-LAB-072 Clients and client copy (Administration Lab, 3 h)\n- BASIS-LAB-073 Program execution, table display and load generation (Administration Lab, 2 h)\n\n### Transaction and System Administration Curriculum\n\nTopics: For every important transaction: purpose, screen or section, what to check, real-world use, common errors, troubleshooting\n\n- ASG-010 Transaction reference part 1: processes, users, logs and dumps (Assignment, 3 h)\n- ASG-011 Transaction reference part 2: jobs, locks, updates, spool and communication (Assignment, 3 h)\n- ASG-012 Transaction reference part 3: configuration, change and security (Assignment, 3 h)\n- ASM-002 Level 2 assessment: Basis administration, users, jobs, transports, monitoring and troubleshooting (Assessment, 4 h)\n\n## Module 30 - HANA Architecture (V08 - HANA Administration)\n\n### SAP HANA Architecture\n\nTopics: In-memory computing; Column store; Row store; Persistence layer; Delta storage; Savepoints; Logs; Index server; Nameserver; Compile server concepts; Preprocessor; XS classic concepts; HANA Cockpit concepts; Flow: SAP application, HANA client, index server, memory, persistence, storage\n\n- THY-049 In-memory computing, column store and row store (Theory, 3 h)\n- THY-050 Persistence: savepoints, redo log and restart (Theory, 3 h)\n- THY-051 Services, tenants and tools (Theory, 3 h)\n- BASIS-LAB-074 Explore the HANA system from the host and SQL (HANA Lab, 3 h)\n\n## Module 31 - HANA Installation (V08 - HANA Administration)\n\n### SAP HANA Installation\n\nTopics: OS preparation; Filesystems; Users; Groups; HANA installation; hdblcm; HANA client; HDBSQL; Post-installation; Services; Configuration\n\n- THY-052 Planning a HANA installation (Theory, 2 h)\n- BASIS-LAB-075 Install SAP HANA with the lifecycle manager (HANA Lab, 4 h)\n- BASIS-LAB-076 Install the client and configure secure logon keys (HANA Lab, 2 h)\n- BASIS-LAB-077 Post-installation: licence, backup, parameters and tenants (HANA Lab, 3 h)\n- INC-052 Incident 052: HANA installation fails in the prerequisite check or service start (Troubleshooting Incident, 1 h)\n- PROJECT-010 Project 9: SAP HANA Installation (Project, 5 h)\n\n## Module 32 - HANA Administration (V08 - HANA Administration)\n\n### SAP HANA System Administration\n\nTopics: HANA services; Start/stop; Configuration; Users; Roles; SQL; HANA Cockpit; HDBSQL; System views; Monitoring; HDB start; HDB stop; HDB info; hdbsql\n\n- THY-053 Operating HANA (Theory, 3 h)\n- BASIS-LAB-078 Start, stop and check HANA (HANA Lab, 2 h)\n- BASIS-LAB-079 Configuration parameters (HANA Lab, 3 h)\n- BASIS-LAB-080 SQL administration and system views (HANA Lab, 3 h)\n- BASIS-LAB-081 HANA cockpit and alerts (HANA Lab, 3 h)\n- BASIS-LAB-082 Housekeeping (HANA Lab, 2 h)\n- INC-053 Incident 053: HANA service stopped: index server of one tenant is down (Troubleshooting Incident, 1 h)\n- INC-054 Incident 054: Connection failure: application cannot connect to HANA (Troubleshooting Incident, 1 h)\n- INC-055 Incident 055: HANA disk full on the trace or log volume (Troubleshooting Incident, 1 h)\n- PROJECT-011 Project 10: HANA Administration (Project, 5 h)\n\n## Module 33 - HANA Security (V08 - HANA Administration)\n\n### SAP HANA User and Security Administration\n\nTopics: HANA users; Roles; Privileges; System privileges; Object privileges; Analytic privileges; Password policy; Authentication; Auditing; Encryption concepts\n\n- THY-054 HANA authorization and authentication (Theory, 3 h)\n- BASIS-LAB-083 Users, roles and privileges (HANA Lab, 3 h)\n- BASIS-LAB-084 Password policy and auditing (HANA Lab, 3 h)\n- THY-055 Encryption concepts (Theory, 2 h)\n- INC-056 Incident 056: HANA user locked: technical user of the application (Troubleshooting Incident, 1 h)\n\n## Module 34 - HANA Backup (V11 - Backup/Recovery)\n\n### SAP HANA Backup\n\nTopics: Data backup; Log backup; Full backup; Incremental backup; Differential concepts; Backup catalog; Backup monitoring\n\n- THY-056 HANA backup concepts (Theory, 3 h)\n- BASIS-LAB-085 Backup lab (HANA Lab, 4 h)\n- BASIS-LAB-086 Backup checks and monitoring (HANA Lab, 2 h)\n- INC-057 Incident 057: HANA backup failure: data backup ends with error (Troubleshooting Incident, 1 h)\n- INC-058 Incident 058: Log backups fail and the log volume fills (Troubleshooting Incident, 1 h)\n\n## Module 35 - HANA Recovery (V11 - Backup/Recovery)\n\n### SAP HANA Recovery\n\nTopics: Recovery; Point-in-time recovery; Recovery validation; Backup catalog; Recovery of system database and tenants\n\n- THY-057 Recovery concepts (Theory, 2 h)\n- BASIS-LAB-087 Recovery lab (HANA Lab, 4 h)\n- BASIS-LAB-088 Point-in-time recovery lab (HANA Lab, 4 h)\n- BASIS-LAB-089 Recover the system database and validate a restore on another host (HANA Lab, 3 h)\n- INC-059 Incident 059: Recovery fails: a log backup is missing (Troubleshooting Incident, 1 h)\n- PROJECT-012 Project 11: HANA Backup & Recovery (Project, 5 h)\n\n## Module 36 - HANA HA (V10 - HA/DR)\n\n### SAP HANA High Availability\n\nTopics: High availability; Single point of failure; HANA System Replication; Primary; Secondary; Sync modes; Operation modes; Takeover; Failback; Monitoring replication\n\n- THY-058 Availability and HANA system replication (Theory, 3 h)\n- BASIS-LAB-090 Configure system replication (HANA Lab, 4 h)\n- BASIS-LAB-091 Monitor replication (HANA Lab, 2 h)\n- BASIS-LAB-092 Takeover and failback (HANA Lab, 4 h)\n- INC-060 Incident 060: Replication broken: secondary shows error and is out of sync (Troubleshooting Incident, 1 h)\n- INC-061 Incident 061: Takeover done but the application cannot connect (Troubleshooting Incident, 1 h)\n- PROJECT-013 Project 12: HANA System Replication (Project, 5 h)\n\n## Module 37 - HANA DR (V10 - HA/DR)\n\n### SAP HANA Disaster Recovery\n\nTopics: DR planning; RPO; RTO; Backup-based DR; HANA System Replication; DR testing; Failover; Failback; DR documentation\n\n- THY-059 Disaster recovery planning (Theory, 3 h)\n- BASIS-LAB-093 Asynchronous replication to a DR site (HANA Lab, 3 h)\n- BASIS-LAB-094 Backup-based DR (HANA Lab, 3 h)\n- ASG-013 Enterprise DR exercise (Assignment, 5 h)\n- INC-062 Incident 062: DR issue: DR site cannot be activated because the licence or keys are missing (Troubleshooting Incident, 1 h)\n\n## Module 38 - HANA Performance (V08 - HANA Administration)\n\n### SAP HANA Performance\n\nTopics: Memory management; CPU; Disk; Expensive SQL; Blocking; Locks; Sessions; Threads; Services; Tables; Delta merge; Garbage collection concepts; Backup performance\n\n- THY-060 HANA memory management (Theory, 3 h)\n- BASIS-LAB-095 Memory analysis (HANA Lab, 3 h)\n- BASIS-LAB-096 Expensive statements, plan cache and threads (HANA Lab, 3 h)\n- BASIS-LAB-097 Blocking, locks and sessions (HANA Lab, 2 h)\n- BASIS-LAB-098 Delta merge, garbage collection and backup performance (HANA Lab, 3 h)\n- INC-063 Incident 063: HANA memory issue: out-of-memory events during reporting (Troubleshooting Incident, 1 h)\n- INC-064 Incident 064: SQL performance: one statement slows the whole system (Troubleshooting Incident, 1 h)\n- INC-065 Incident 065: HANA CPU saturation (Troubleshooting Incident, 1 h)\n\n## Module 39 - S/4HANA Architecture (V09 - S/4HANA)\n\n### SAP S/4HANA Technical Architecture\n\nTopics: S/4HANA architecture; ABAP stack; HANA database; Fiori; Gateway; Web Dispatcher; ASCS; PAS; AAS; ERS; Integration layer; Flow: users, browser or SAP GUI, Web Dispatcher, Fiori and Gateway, S/4HANA application layer, HANA\n\n- THY-061 S/4HANA from the Basis view (Theory, 3 h)\n- BASIS-LAB-099 Explore the S/4HANA technical components (Administration Lab, 3 h)\n- PROJECT-014 Project 13: S/4HANA Technical Administration (Project, 6 h)\n\n## Module 40 - Fiori Administration (V09 - S/4HANA)\n\n### SAP Fiori Administration\n\nTopics: Fiori architecture; Fiori Launchpad; Frontend; Backend; OData; Gateway; Catalogs; Groups; Spaces; Pages; Business roles; Services; ICF; Troubleshooting\n\n- THY-062 Fiori architecture and content model (Theory, 3 h)\n- BASIS-LAB-100 Launchpad setup with task lists (Configuration, 4 h)\n- BASIS-LAB-101 Activate an app and assign it by business role (Configuration, 4 h)\n- BASIS-LAB-102 Fiori troubleshooting lab (Administration Lab, 4 h)\n- INC-066 Incident 066: Fiori failure: launchpad does not load (Troubleshooting Incident, 1 h)\n- INC-067 Incident 067: Fiori failure: tile is missing for one user (Troubleshooting Incident, 1 h)\n- INC-068 Incident 068: Fiori failure: app shows old version after a transport (Troubleshooting Incident, 1 h)\n- PROJECT-015 Project 14: Fiori Administration (Project, 5 h)\n\n## Module 41 - Gateway & OData (V09 - S/4HANA)\n\n### SAP Gateway and OData\n\nTopics: SAP Gateway; OData; Services; Service activation; ICF; Authentication; Authorization; Backend connectivity; Error analysis; HTTP 401, 403, 404, 500\n\n- THY-063 Gateway and OData for administrators (Theory, 3 h)\n- BASIS-LAB-103 Activate, test and trace OData services (Administration Lab, 3 h)\n- INC-069 Incident 069: OData failure: 401 unauthorized (Troubleshooting Incident, 1 h)\n- INC-070 Incident 070: OData failure: 403 forbidden (Troubleshooting Incident, 1 h)\n- INC-071 Incident 071: OData failure: 404 not found or service inactive (Troubleshooting Incident, 1 h)\n- INC-072 Incident 072: OData failure: 500 internal server error from the back end (Troubleshooting Incident, 1 h)\n\n## Module 42 - SAP Security (V07 - Security)\n\n### SAP Security for Basis\n\nTopics: Authentication; Authorization; Roles; Users; SNC; TLS; Certificates; STRUST; SAProuter security; Network security; Secure RFC; Password policies; Audit logging; Security patches; Hardening; Segregation of duties; Cooperation of SAP Security, Basis, network, Linux and database teams\n\n- THY-064 The Basis part of SAP security (Theory, 3 h)\n- BASIS-LAB-104 Security audit log (Administration Lab, 3 h)\n- BASIS-LAB-105 Secure RFC and gateway hardening (Administration Lab, 3 h)\n- BASIS-LAB-106 Encrypted GUI and RFC communication (Administration Lab, 3 h)\n- THY-065 Security patches, system recommendations and hardening baselines (Theory, 2 h)\n- PROJECT-016 Security Hardening Project (authorized lab) (Project, 8 h)\n- INC-073 Incident 073: Users cannot log on after password policy parameters were changed (Troubleshooting Incident, 1 h)\n- INC-074 Incident 074: Interface stops after gateway access lists were tightened (Troubleshooting Incident, 1 h)\n\n## Module 43 - Certificates (V07 - Security)\n\n### SAP Certificate Management\n\nTopics: SSL/TLS; PSE; STRUST; Root CA; Intermediate CA; Server certificates; Client certificates; Certificate renewal; Certificate troubleshooting\n\n- THY-066 TLS, certificates and PSEs in SAP (Theory, 3 h)\n- BASIS-LAB-107 Server certificate from a lab certificate authority (Administration Lab, 4 h)\n- BASIS-LAB-108 Outbound HTTPS and client certificates (Administration Lab, 3 h)\n- BASIS-LAB-109 Web dispatcher and command-line PSE handling (Administration Lab, 2 h)\n- BASIS-LAB-110 Certificate renewal and expiry monitoring (Administration Lab, 3 h)\n- INC-075 Incident 075: Certificate expiry: users get browser errors on Monday morning (Troubleshooting Incident, 1 h)\n- INC-076 Incident 076: Certificate problem: chain incomplete for some clients (Troubleshooting Incident, 1 h)\n- INC-077 Incident 077: Outbound HTTPS call fails with a trust error (Troubleshooting Incident, 1 h)\n\n## Module 44 - System Copy (V12 - Upgrade/Migration)\n\n### SAP System Copy\n\nTopics: Homogeneous system copy; Heterogeneous system copy concepts; Database copy; Application server copy; Post-copy activities; Logical system; RFC destinations; Jobs; Interfaces; Printers; BDLS concepts; SLICENSE; Environment validation\n\n- THY-067 System copy methods (Theory, 3 h)\n- BASIS-LAB-111 Homogeneous system copy with backup and restore (Installation Lab, 6 h)\n- BASIS-LAB-112 Post-copy activities (Administration Lab, 5 h)\n- INC-078 Incident 078: System copy issue: target does not start after the copy (Troubleshooting Incident, 1 h)\n- INC-079 Incident 079: System copy issue: copied system sends messages to production partners (Troubleshooting Incident, 1 h)\n- PROJECT-017 Project 18: System Copy (Project, 6 h)\n\n## Module 45 - System Refresh (V12 - Upgrade/Migration)\n\n### SAP System Refresh\n\nTopics: Refresh lifecycle: planning, backup, source preparation, target preparation, database restore or copy, post-copy activities, logical system, RFC, jobs, interfaces, validation, testing\n\n- THY-068 Refresh versus copy and the refresh lifecycle (Theory, 2 h)\n- BASIS-LAB-113 Refresh preparation: save target-specific data (Administration Lab, 3 h)\n- BASIS-LAB-114 Refresh the database and restart isolated (Installation Lab, 4 h)\n- BASIS-LAB-115 Refresh post-processing and validation (Administration Lab, 5 h)\n- INC-080 Incident 080: Refresh issue: jobs from the source start running in the refreshed system (Troubleshooting Incident, 1 h)\n- INC-081 Incident 081: Refresh issue: users of the target system are gone (Troubleshooting Incident, 1 h)\n- INC-082 Incident 082: Refresh issue: logical system conversion runs for many hours (Troubleshooting Incident, 1 h)\n- PROJECT-018 Project 19: System Refresh (QAS Refresh Project) (Project, 6 h)\n- PROJECT-019 DEV Refresh Project (Project, 4 h)\n\n## Module 46 - License Management (V04 - Core Basis)\n\n### SAP License Management\n\nTopics: SAP license concepts; System measurement concepts; License keys; Hardware keys; License troubleshooting; SLICENSE; System identification\n\n- THY-069 Licences, keys and measurement (Theory, 2 h)\n- BASIS-LAB-116 Licence administration (Administration Lab, 2 h)\n- INC-083 Incident 083: System accepts logons only from the emergency user: licence expired (Troubleshooting Incident, 1 h)\n\n## Module 47 - Upgrade (V12 - Upgrade/Migration)\n\n### SAP Upgrade\n\nTopics: Upgrade planning; Compatibility; Maintenance Planner; Stack XML; SUM; SPAM/SAINT concepts; Kernel upgrade; Add-ons; Custom code considerations; Testing; Downtime; Shadow system concepts; SPAU; SPDD; Post-upgrade validation; Rollback/contingency planning\n\n- THY-070 The upgrade lifecycle (Theory, 3 h)\n- BASIS-LAB-117 Plan an upgrade in the Maintenance Planner (or on paper) (Administration Lab, 3 h)\n- BASIS-LAB-118 Upgrade rehearsal with the Software Update Manager (Installation Lab, 6 h)\n- BASIS-LAB-119 Post-upgrade validation (Administration Lab, 2 h)\n- INC-084 Incident 084: Upgrade issue: tool stops with an error in a preprocessing phase (Troubleshooting Incident, 1 h)\n- INC-085 Incident 085: Upgrade issue: dumps after go-live in modified objects (Troubleshooting Incident, 1 h)\n- PROJECT-020 Project 20: SAP Upgrade (Project, 6 h)\n\n## Module 48 - Migration (V12 - Upgrade/Migration)\n\n### SAP S/4HANA Migration\n\nTopics: ECC to S/4HANA; System Conversion; New Implementation; Selective Data Transition concepts; Readiness checks; Simplification items; Custom code migration concepts; Database migration; SUM/DMO concepts; Testing; Cutover; Downtime optimization; Post-migration validation\n\n- THY-071 Paths to S/4HANA (Theory, 3 h)\n- THY-072 Conversion with the update manager and database migration option (Theory, 3 h)\n\n### Database Migration\n\nTopics: Heterogeneous migration concepts; Homogeneous migration; SAP HANA migration; DMO; Export/import concepts; Backup/restore; Downtime; Validation; Performance validation\n\n- THY-073 Database migration methods (Theory, 3 h)\n- ASG-014 Migration validation plan (Assignment, 3 h)\n- INC-086 Incident 086: Migration issue: export or import of one large table fails repeatedly (Troubleshooting Incident, 1 h)\n- PROJECT-021 Project 21: ECC to S/4HANA Migration Concepts (Project, 6 h)\n\n## Module 49 - HA & Clustering (V10 - HA/DR)\n\n### SAP High Availability and Clustering\n\nTopics: ASCS HA; ERS; Pacemaker; Corosync; Shared storage; Virtual IP; HANA System Replication; Load balancing; Application server redundancy\n\n- THY-074 High availability architecture for SAP (Theory, 4 h)\n- BASIS-LAB-120 Cluster basics with a simple resource (Administration Lab, 4 h)\n- BASIS-LAB-121 ASCS and ERS in the cluster (Installation Lab, 6 h)\n- BASIS-LAB-122 HANA system replication under cluster control (Administration Lab, 4 h)\n- BASIS-LAB-123 Controlled failover tests (Administration Lab, 3 h)\n- INC-087 Incident 087: HA failover issue: cluster does not fail over because fencing fails (Troubleshooting Incident, 1 h)\n- INC-088 Incident 088: HA failover issue: locks are lost after central services failover (Troubleshooting Incident, 1 h)\n- INC-089 Incident 089: HA failover issue: resource fails back and forth (Troubleshooting Incident, 1 h)\n- PROJECT-022 Project 16: SAP HA (Project, 8 h)\n\n## Module 50 - Backup Strategy (V11 - Backup/Recovery)\n\n### SAP Backup Strategy\n\nTopics: Database backup; Filesystem backup; Configuration backup; SAP profiles; Kernel backup; Transport backup; Backup retention; Encryption; Offsite backup; Immutable backup concepts; Backup validation; Restore testing\n\n- THY-075 What to back up and how to keep it (Theory, 3 h)\n- BASIS-LAB-124 Filesystem and configuration backup with restore test (Administration Lab, 4 h)\n- ASG-015 Enterprise backup policy (Assignment, 4 h)\n- INC-090 Incident 090: Backup issue: restore test shows that backups of one filesystem were empty for weeks (Troubleshooting Incident, 1 h)\n\n## Module 51 - Disaster Recovery (V10 - HA/DR)\n\n### SAP Disaster Recovery\n\nTopics: DR architecture; RPO; RTO; DR sites; Replication; Backup-based recovery; HANA replication; Failover; Failback; DR drills; Business continuity\n\n- THY-076 Disaster recovery architecture for an SAP landscape (Theory, 3 h)\n- INC-091 Incident 091: DR issue: application servers at the DR site do not start after database takeover (Troubleshooting Incident, 1 h)\n- PROJECT-023 Project 17: SAP DR (Complete SAP DR Project) (Project, 8 h)\n- ASM-003 Level 3 assessment: HANA, S/4HANA, Fiori, security and HA/DR (Assessment, 4 h)\n\n## Module 52 - Cloud (V13 - Cloud)\n\n### SAP on Cloud Infrastructure\n\nTopics: SAP on AWS; SAP on Azure; SAP on Google Cloud; SAP cloud infrastructure; Virtual machines; Storage; Networking; Load balancing; Security groups; Backup; HA; DR; Monitoring; SAP RISE; SAP S/4HANA Cloud; SAP BTP; SAP Cloud ALM\n\n- THY-077 SAP on hyperscaler infrastructure (Theory, 4 h)\n- THY-078 HA, DR, backup and monitoring in the cloud (Theory, 3 h)\n- THY-079 RISE with SAP, S/4HANA Cloud, BTP and Cloud ALM (Theory, 3 h)\n- ASG-016 Cloud architecture design for the lab landscape (Assignment, 4 h)\n- INC-092 Incident 092: Cloud issue: virtual address does not move after a cluster failover (Troubleshooting Incident, 1 h)\n\n## Module 53 - Automation (V14 - Automation)\n\n### SAP Automation\n\nTopics: Shell: Bash automation; Ansible: OS preparation, SAP packages, configuration, monitoring, user creation, filesystems, SAP services; Python: SAP APIs, automation, REST, JSON, monitoring scripts; Infrastructure as Code: Terraform, cloud infrastructure, configuration management\n\n- BASIS-LAB-125 Consolidate the Bash tool set (Administration Lab, 3 h)\n- THY-080 Ansible fundamentals (Theory, 3 h)\n- BASIS-LAB-126 Ansible: operating system preparation for SAP (Administration Lab, 4 h)\n- BASIS-LAB-127 Ansible: SAP services, configuration and monitoring agents (Administration Lab, 4 h)\n- BASIS-LAB-128 Ansible: user creation and housekeeping (Administration Lab, 2 h)\n- THY-081 Python for Basis: APIs, REST and JSON (Theory, 2 h)\n- BASIS-LAB-129 Python: monitoring scripts (Administration Lab, 4 h)\n- THY-082 Infrastructure as code with Terraform (Theory, 2 h)\n- BASIS-LAB-130 Terraform: describe the lab landscape (Administration Lab, 3 h)\n- PROJECT-024 Project 23: SAP Basis Automation with Ansible (Project, 8 h)\n\n## Module 54 - Observability (V14 - Automation)\n\n### SAP Monitoring and Observability\n\nTopics: SAP monitoring; Prometheus; Grafana; Alertmanager; Zabbix; OpenTelemetry concepts; Loki/log aggregation concepts; Centralized logging; Flow: SAP, metrics and logs, collectors, monitoring platform, Grafana, alerts, incident management\n\n- THY-083 Observability architecture for SAP (Theory, 3 h)\n- BASIS-LAB-131 Install Prometheus, Grafana and Alertmanager (Administration Lab, 3 h)\n- BASIS-LAB-132 Collect SAP and HANA metrics (Administration Lab, 4 h)\n- BASIS-LAB-133 Dashboards (Administration Lab, 5 h)\n- BASIS-LAB-134 Alert rules and routing (Administration Lab, 3 h)\n- BASIS-LAB-135 Centralized logging (Administration Lab, 3 h)\n- PROJECT-025 Project 22: SAP Monitoring with Grafana (Project, 6 h)\n\n## Module 55 - Incident Management (V15 - Production Support)\n\n### SAP Incident Management\n\nTopics: Incident; Problem; Change; Request; SLA; Priority; Severity; Escalation; RCA; Knowledge management\n\n- THY-084 Incident, problem, change and request (Theory, 3 h)\n- PRD-001 Production incident 01: Month-end: users report the system is extremely slow (Production Incident, 2 h)\n- PRD-002 Production incident 02: Interface to the bank has delivered nothing since last night (Production Incident, 1 h)\n- PRD-003 Production incident 03: All users are logged off and cannot log on again (Production Incident, 2 h)\n- PRD-004 Production incident 04: Background jobs have been delayed for hours (Production Incident, 1 h)\n- PRD-005 Production incident 05: Printing fails in the warehouse (Production Incident, 1 h)\n- PRD-006 Production incident 06: Fiori launchpad shows an error page for everyone (Production Incident, 1 h)\n- PRD-007 Production incident 07: Transport to production failed during the release window (Production Incident, 1 h)\n- PRD-008 Production incident 08: Database log volume is filling fast (Production Incident, 1 h)\n- PRD-009 Production incident 09: One application server restarts every few hours (Production Incident, 1 h)\n- PRD-010 Production incident 10: Users in one country cannot connect (Production Incident, 1 h)\n- PRD-011 Production incident 11: Security team reports a default password on a standard user (Production Incident, 1 h)\n- PRD-012 Production incident 12: Disk space alert on the transport directory (Production Incident, 1 h)\n- RCA-001 RCA: major incident from this module (RCA, 3 h)\n- ASG-017 Knowledge base articles (Assignment, 2 h)\n\n## Module 56 - Troubleshooting (V15 - Production Support)\n\n### SAP Troubleshooting Master Course\n\nTopics: Flow for every incident: incident, impact, detection, initial checks, evidence, root cause, fix, validation, RCA, prevention; Categories: OS, SAP, HANA, network\n\n- THY-085 The troubleshooting method (Theory, 2 h)\n- INC-093 Incident 093: OS: /usr/sap filesystem full, instance processes die (Troubleshooting Incident, 1 h)\n- INC-094 Incident 094: OS: CPU high from a runaway non-SAP process (Troubleshooting Incident, 1 h)\n- INC-095 Incident 095: OS: memory exhausted and the kernel kills a process (Troubleshooting Incident, 1 h)\n- INC-096 Incident 096: OS: NFS unavailable for /sapmnt on an application server (Troubleshooting Incident, 1 h)\n- INC-097 Incident 097: OS: process failure, start service of one instance is gone (Troubleshooting Incident, 1 h)\n- INC-098 Incident 098: OS: time jump on a host breaks logons and jobs (Troubleshooting Incident, 1 h)\n- INC-099 Incident 099: OS: inode exhaustion although space is free (Troubleshooting Incident, 1 h)\n- INC-100 Incident 100: OS: host reboots and the SAP system does not come back (Troubleshooting Incident, 1 h)\n- INC-101 Incident 101: SAP: system unavailable, no instance answers (Troubleshooting Incident, 1 h)\n- INC-102 Incident 102: SAP: instance won't start after a host name change (Troubleshooting Incident, 1 h)\n- INC-103 Incident 103: SAP: work process unavailable, all update processes stopped (Troubleshooting Incident, 1 h)\n- INC-104 Incident 104: SAP: dispatcher failure, dispatcher ends shortly after start (Troubleshooting Incident, 1 h)\n- INC-105 Incident 105: SAP: message server failure, application servers lose contact (Troubleshooting Incident, 1 h)\n- INC-106 Incident 106: SAP: gateway failure, external program connections refused (Troubleshooting Incident, 1 h)\n- INC-107 Incident 107: SAP: ICM failure, all HTTP requests hang (Troubleshooting Incident, 1 h)\n- INC-108 Incident 108: SAP: lock issue, mass locks from one batch job block users (Troubleshooting Incident, 1 h)\n- INC-109 Incident 109: SAP: update failure, V2 updates pile up (Troubleshooting Incident, 1 h)\n- INC-110 Incident 110: SAP: job failure, a whole job chain stops overnight (Troubleshooting Incident, 1 h)\n- INC-111 Incident 111: SAP: spool failure, spool work process in error (Troubleshooting Incident, 1 h)\n- INC-112 Incident 112: SAP: RFC failure, calls to one system time out (Troubleshooting Incident, 1 h)\n- INC-113 Incident 113: SAP: logon possible but every transaction dumps (Troubleshooting Incident, 1 h)\n- INC-114 Incident 114: SAP: number range buffer or enqueue timeouts after failover (Troubleshooting Incident, 1 h)\n- INC-115 Incident 115: HANA: HANA unavailable after a host restart (Troubleshooting Incident, 1 h)\n- INC-116 Incident 116: HANA: memory exhaustion, system near the allocation limit (Troubleshooting Incident, 1 h)\n- INC-117 Incident 117: HANA: disk full on the data volume (Troubleshooting Incident, 1 h)\n- INC-118 Incident 118: HANA: backup failure, backup destination unreachable (Troubleshooting Incident, 1 h)\n- INC-119 Incident 119: HANA: replication broken after network maintenance (Troubleshooting Incident, 1 h)\n- INC-120 Incident 120: HANA: SQL performance, statement plan changed after an update (Troubleshooting Incident, 1 h)\n- INC-121 Incident 121: HANA: service stopped, name server restarts repeatedly (Troubleshooting Incident, 1 h)\n- INC-122 Incident 122: HANA: connection failure, connection limit reached (Troubleshooting Incident, 1 h)\n- INC-123 Incident 123: HANA: long savepoints freeze commits (Troubleshooting Incident, 1 h)\n- INC-124 Incident 124: Network: DNS failure after a resolver change (Troubleshooting Incident, 1 h)\n- INC-125 Incident 125: Network: port blocked after a firewall rule update (Troubleshooting Incident, 1 h)\n- INC-126 Incident 126: Network: firewall issue, idle connections dropped (Troubleshooting Incident, 1 h)\n- INC-127 Incident 127: Network: certificate problem, system-to-system HTTPS fails after a CA change (Troubleshooting Incident, 1 h)\n- INC-128 Incident 128: Network: load balancer failure, health check marks all servers down (Troubleshooting Incident, 1 h)\n- INC-129 Incident 129: Network: high latency between application server and database (Troubleshooting Incident, 1 h)\n- INC-130 Incident 130: Multi-fault case: Monday morning after a maintenance weekend (Troubleshooting Incident, 4 h)\n- RCA-002 RCA: multi-fault case (RCA, 3 h)\n- ASM-004 Troubleshooting assessment (Assessment, 4 h)\n\n## Module 57 - Production Support (V15 - Production Support)\n\n### SAP Production Support\n\nTopics: Daily health checks; Weekly checks; Monthly checks; Patch management; Capacity management; Performance management; Backup validation; DR testing; Security checks; Transport monitoring; Job monitoring; Interface monitoring; Certificate monitoring; License monitoring\n\n- THY-086 The operations calendar (Theory, 3 h)\n- BASIS-LAB-136 Daily Basis health check (Administration Lab, 4 h)\n- BASIS-LAB-137 Weekly and monthly checks (Administration Lab, 3 h)\n- BASIS-LAB-138 Patch and capacity management (Administration Lab, 3 h)\n- ASG-018 Recurring operational checklist in Redmine (Assignment, 2 h)\n- PROJECT-026 SAP Basis Automated Health Check Project (Project, 8 h)\n- RCA-003 RCA: finding from the health checks (RCA, 2 h)\n- PROJECT-027 Project 24: Enterprise Production Support (Project, 8 h)\n\n## Module 58 - Real-World Projects (V16 - Expert Architecture)\n\n### Enterprise SAP Landscape Architecture\n\nTopics: Enterprise landscape design; Sizing; System landscape tiers; Network zones; HA and DR design; Operations model; Technical architecture documents\n\n- THY-087 Designing enterprise SAP landscapes (Theory, 4 h)\n- ASG-019 Architecture design for a client brief (Assignment, 6 h)\n\n### Documentation Training\n\nTopics: SAP landscape document; Architecture diagram; Server inventory; Port matrix; Filesystem document; SAP instance document; HANA architecture document; Backup policy; DR document; HA document; Monitoring document; Security document; Transport document; Upgrade document; Migration document; Daily health-check document; Troubleshooting runbook; RCA document; Production support runbook\n\n- DOC-001 Landscape documentation set part 1 (Documentation, 5 h)\n- DOC-002 Landscape documentation set part 2 (Documentation, 5 h)\n- DOC-003 Landscape documentation set part 3 (Documentation, 5 h)\n\n### Real-World Incident Bank\n\nTopics: The full bank of production scenarios is on the Incident_Bank wiki page: every troubleshooting incident, production incident and capstone failure of this programme plus further scenarios worked here on paper\n\n- ASG-020 Incident bank pack 01: ten further production scenarios (Assignment, 3 h)\n- ASG-021 Incident bank pack 02: ten further production scenarios (Assignment, 3 h)\n- ASG-022 Incident bank pack 03: ten further production scenarios (Assignment, 3 h)\n- ASG-023 Incident bank pack 04: ten further production scenarios (Assignment, 3 h)\n\n### Interview Preparation\n\nTopics: For every question: question, short answer, detailed answer, real-world example, troubleshooting angle, common mistake\n\n- INT-001 Interview questions: SAP Basis beginner questions (Interview Question, 2 h)\n- INT-002 Interview questions: Linux questions (Interview Question, 2 h)\n- INT-003 Interview questions: Networking questions (Interview Question, 2 h)\n- INT-004 Interview questions: SAP architecture questions (Interview Question, 2 h)\n- INT-005 Interview questions: Installation questions (Interview Question, 2 h)\n- INT-006 Interview questions: Kernel questions (Interview Question, 2 h)\n- INT-007 Interview questions: Work process questions (Interview Question, 2 h)\n- INT-008 Interview questions: Job questions (Interview Question, 2 h)\n- INT-009 Interview questions: Transport questions (Interview Question, 2 h)\n- INT-010 Interview questions: Monitoring questions (Interview Question, 2 h)\n- INT-011 Interview questions: Performance questions (Interview Question, 2 h)\n- INT-012 Interview questions: HANA questions (Interview Question, 3 h)\n- INT-013 Interview questions: S/4HANA questions (Interview Question, 2 h)\n- INT-014 Interview questions: Security questions (Interview Question, 2 h)\n- INT-015 Interview questions: HA/DR questions (Interview Question, 3 h)\n- INT-016 Interview questions: Upgrade questions (Interview Question, 2 h)\n- INT-017 Interview questions: Migration questions (Interview Question, 2 h)\n- INT-018 Interview questions: Production support questions (Interview Question, 2 h)\n- INT-019 Interview questions: Scenario-based questions (Interview Question, 3 h)\n- INT-020 Interview questions: Architect-level questions (Interview Question, 3 h)\n\n### Career Preparation\n\nTopics: SAP Basis resume: technical skills, SAP systems, HANA, Linux, HA/DR, monitoring, automation, projects; LinkedIn: headline, about section, skills, project descriptions; Interview: technical questions, scenario questions, production incidents, architecture questions; Project explanation: project, landscape, my role, implementation, configuration, issue, troubleshooting, resolution, business impact\n\n- DOC-004 SAP Basis resume (Documentation, 3 h)\n- DOC-005 LinkedIn profile (Documentation, 2 h)\n- ASG-024 Project explanation practice (Assignment, 3 h)\n- ASM-005 Mock interviews: technical, scenario, production incident and architecture (Assessment, 3 h)\n- ASM-006 Level 4 assessment: architecture, migration, upgrade, automation, cloud and production support (Assessment, 4 h)\n\n## Module 59 - Final Capstone (V17 - Final Capstone)\n\n### Capstone: Global Enterprise SAP Landscape\n\nTopics: Landscape: Internet, SAP Web Dispatcher, Fiori and SAP GUI, S/4HANA application with PAS, AAS, ASCS and ERS, SAP HANA with HANA secondary; Implement Linux servers, S/4HANA, HANA, ASCS, ERS, PAS, AAS, Web Dispatcher, Fiori, users, roles, RFC, jobs, spool, transports, monitoring, backup, HA, DR, security, certificates and automation; Operations: installation, administration, monitoring, security, transport, backup, recovery, HA, DR, upgrade, migration, automation, troubleshooting\n\n- CAP-001 Installation: design and build the landscape (Capstone Task, 16 h)\n- CAP-002 Administration: manage the SAP instances (Capstone Task, 6 h)\n- CAP-003 Fiori and user access (Capstone Task, 6 h)\n- CAP-004 Security: users, roles, certificates and hardening (Capstone Task, 8 h)\n- CAP-005 Transport: implement DEV to QAS to PRD (Capstone Task, 5 h)\n- CAP-006 Monitoring: SAP, HANA and OS (Capstone Task, 6 h)\n- CAP-007 Backup: configure and validate backups (Capstone Task, 4 h)\n- CAP-008 Recovery: perform recovery exercises (Capstone Task, 5 h)\n- CAP-009 HA: perform controlled failover (Capstone Task, 6 h)\n- CAP-010 DR: perform DR simulation (Capstone Task, 5 h)\n- CAP-011 Upgrade: prepare upgrade strategy (Capstone Task, 4 h)\n- CAP-012 Migration: prepare S/4HANA migration strategy (Capstone Task, 4 h)\n- CAP-013 Automation: automate health checks (Capstone Task, 4 h)\n- FAIL-001 Failure 01: stop SAP instance (Capstone Task, 1 h)\n- FAIL-002 Failure 02: stop HANA service (Capstone Task, 1 h)\n- FAIL-003 Failure 03: fill test filesystem (Capstone Task, 1 h)\n- FAIL-004 Failure 04: stop application server (Capstone Task, 1 h)\n- FAIL-005 Failure 05: break test RFC (Capstone Task, 1 h)\n- FAIL-006 Failure 06: expire test certificate (Capstone Task, 1 h)\n- FAIL-007 Failure 07: stop Web Dispatcher (Capstone Task, 1 h)\n- FAIL-008 Failure 08: create test job failure (Capstone Task, 1 h)\n- FAIL-009 Failure 09: create test lock (Capstone Task, 1 h)\n- FAIL-010 Failure 10: create test update failure (Capstone Task, 1 h)\n- FAIL-011 Failure 11: break HANA replication (Capstone Task, 1 h)\n- FAIL-012 Failure 12: simulate backup failure (Capstone Task, 1 h)\n- FAIL-013 Failure 13: simulate network connectivity failure (Capstone Task, 1 h)\n- RCA-004 RCA: capstone failure injection (RCA, 3 h)\n- CAP-014 Final documentation and presentation (Capstone Task, 6 h)\n- ASM-007 Final assessment (Assessment, 4 h)\n",
   "parent": "Wiki"
  }
 ]
}
