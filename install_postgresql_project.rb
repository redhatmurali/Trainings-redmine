# PostgreSQL Database Engineering & Development - one-shot Redmine installer
#
# Put this file and postgresql_issues.csv in the same folder. Run on the Redmine server,
# from the Redmine root directory, as the Redmine OS user:
#
#   STUDENTS=alice,bob INSTRUCTORS=admin \
#     bundle exec rails runner -e production /path/to/install_postgresql_project.rb
#
# Environment variables (all optional):
#   CSV            path to postgresql_issues.csv (default: same folder as this script)
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
csv_path   = File.join(course_dir, 'postgresql_issues.csv') if csv_path.empty?
halt("not found: #{csv_path} (set CSV=/path/to/postgresql_issues.csv)") unless File.file?(csv_path)

# The project definition (fields, queries, wiki pages) is embedded at the end of this file.
embedded = File.read(File.expand_path(__FILE__), :encoding => 'utf-8').split("\n__END__\n", 2)[1]
halt('embedded project definition missing from this script') if embedded.to_s.strip.empty?
course = JSON.parse(embedded)
$tag   = course['tag'].to_s.empty? ? 'course' : course['tag']
rows   = CSV.read(csv_path, :headers => true, :encoding => 'bom|utf-8').map(&:to_h)
halt('postgresql_issues.csv is empty') if rows.empty?
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

readonly_core = %w(tracker_id subject description priority_id category_id fixed_version_id
                   assigned_to_id parent_issue_id estimated_hours start_date due_date)
all_t.each do |t|
  WorkflowPermission.where(:tracker_id => t.id, :role_id => role['Student'].id).delete_all
  fields = readonly_core + t.custom_fields.map { |f| f.id.to_s }
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
 "tag": "postgresql",
 "project": {
  "name": "PostgreSQL Database Engineering & Development",
  "identifier": "postgresql-database-engineering-development",
  "description": "Job-oriented PostgreSQL programme combining administration and development: SQL, PL/pgSQL, design, performance, security, backup and recovery, replication, high availability, monitoring, automation, DevOps and cloud, across 20 phases ending in an enterprise database platform capstone. Every topic follows Concept -> Implementation -> Lab -> Troubleshooting -> Performance -> Security -> Automation -> Assessment. One shared project; every student has a personal copy of each issue."
 },
 "trackers": [
  {
   "name": "Epic",
   "kind": "container"
  },
  {
   "name": "Phase",
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
   "name": "SQL Development",
   "kind": "work"
  },
  {
   "name": "DBA",
   "kind": "work"
  },
  {
   "name": "Configuration",
   "kind": "work"
  },
  {
   "name": "Lab",
   "kind": "work"
  },
  {
   "name": "Troubleshooting",
   "kind": "work"
  },
  {
   "name": "Performance",
   "kind": "work"
  },
  {
   "name": "Security",
   "kind": "work"
  },
  {
   "name": "Automation",
   "kind": "work"
  },
  {
   "name": "Assignment",
   "kind": "work"
  },
  {
   "name": "Project",
   "kind": "work"
  },
  {
   "name": "Assessment",
   "kind": "work"
  },
  {
   "name": "Documentation",
   "kind": "work"
  },
  {
   "name": "Review",
   "kind": "work"
  },
  {
   "name": "Capstone",
   "kind": "work"
  }
 ],
 "activities": [
  "Learning",
  "Lab",
  "Configuration",
  "Development",
  "Troubleshooting",
  "Documentation",
  "Testing",
  "Review",
  "Design",
  "Performance Analysis"
 ],
 "versions": [
  "V01.0 Linux & Database Fundamentals",
  "V02.0 PostgreSQL Architecture",
  "V03.0 SQL Fundamentals",
  "V04.0 Advanced SQL",
  "V05.0 Database Design",
  "V06.0 PostgreSQL Development",
  "V07.0 Indexing & Query Optimization",
  "V08.0 Transactions & MVCC",
  "V09.0 Vacuum & Storage",
  "V10.0 Partitioning",
  "V11.0 PostgreSQL Security",
  "V12.0 Backup & Recovery",
  "V13.0 Replication",
  "V14.0 High Availability",
  "V15.0 Performance Engineering",
  "V16.0 Monitoring & Observability",
  "V17.0 Automation & DevOps",
  "V18.0 Cloud & Kubernetes",
  "V19.0 Advanced PostgreSQL Engineering",
  "V20.0 Enterprise Capstone"
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
   "name": "Difficulty",
   "format": "list",
   "trackers": "work",
   "csv": "Difficulty",
   "sort": true
  },
  {
   "name": "Lab Type",
   "format": "list",
   "trackers": "work",
   "csv": "Lab Type"
  },
  {
   "name": "Environment",
   "format": "list",
   "trackers": "all",
   "csv": "Environment"
  },
  {
   "name": "Evidence Required",
   "format": "list",
   "trackers": "work",
   "csv": "Evidence Required"
  },
  {
   "name": "Tool",
   "format": "list",
   "multiple": true,
   "trackers": "all",
   "csv": "Tool",
   "sort": true
  },
  {
   "name": "PostgreSQL Version",
   "format": "string",
   "trackers": "all",
   "csv": "PostgreSQL Version"
  },
  {
   "name": "Skill Track",
   "format": "list",
   "trackers": "all",
   "values": [
    "DBA",
    "Developer",
    "Engineering"
   ],
   "csv": "Skill Track"
  },
  {
   "name": "Production Relevance",
   "format": "list",
   "trackers": "all",
   "values": [
    "High",
    "Medium",
    "Low"
   ],
   "csv": "Production Relevance"
  },
  {
   "name": "Skill Level",
   "format": "list",
   "trackers": "all",
   "csv": "Skill Level",
   "sort": true
  },
  {
   "name": "Assessment Type",
   "format": "list",
   "trackers": "work",
   "csv": "Assessment Type"
  },
  {
   "name": "Portfolio Project",
   "format": "bool",
   "trackers": "work",
   "csv": "Portfolio Project"
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
  },
  {
   "name": "Assessment Score",
   "format": "int",
   "trackers": [
    "Assessment",
    "Project",
    "Capstone"
   ]
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
      "tracker:Epic+Phase+Module"
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
   "name": "My remaining work",
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
      "tracker:Epic+Phase+Module"
     ]
    ],
    [
     "status_id",
     "o",
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
      "tracker:Epic+Phase+Module"
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
   "name": "My assessments",
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
   "name": "My portfolio projects",
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
     "cf:Portfolio Project",
     "=",
     [
      "1"
     ]
    ]
   ],
   "columns": [
    "cf:Curriculum ID",
    "subject",
    "status",
    "cf:Assessment Score"
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
    "done_ratio"
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
   "name": "Dashboard: phase completion",
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
      "tracker:Phase"
     ]
    ]
   ],
   "columns": [
    "cf:Curriculum ID",
    "subject",
    "status",
    "done_ratio"
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
   "name": "Dashboard: labs completed",
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
      "status:Completed"
     ]
    ],
    [
     "tracker_id",
     "=",
     [
      "tracker:Lab+SQL Development+DBA+Configuration+Performance+Security+Automation"
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
   "name": "Dashboard: assessment completion",
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
      "tracker:Assessment+Review"
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
   "name": "Dashboard: DBA skills",
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
      "tracker:Epic+Phase+Module"
     ]
    ],
    [
     "status_id",
     "*",
     null
    ],
    [
     "cf:Skill Track",
     "=",
     [
      "DBA"
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
   "name": "Dashboard: Developer skills",
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
      "tracker:Epic+Phase+Module"
     ]
    ],
    [
     "status_id",
     "*",
     null
    ],
    [
     "cf:Skill Track",
     "=",
     [
      "Developer"
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
   "name": "Dashboard: Engineering skills",
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
      "tracker:Epic+Phase+Module"
     ]
    ],
    [
     "status_id",
     "*",
     null
    ],
    [
     "cf:Skill Track",
     "=",
     [
      "Engineering"
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
   "name": "Dashboard: projects completed",
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
      "status:Completed"
     ]
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
    "cf:Assessment Score",
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
   "name": "Dashboard: troubleshooting cases",
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
      "tracker:Troubleshooting"
     ]
    ]
   ],
   "columns": [
    "cf:Curriculum ID",
    "subject",
    "status",
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
   "name": "Dashboard: capstone status",
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
      "tracker:Capstone"
     ]
    ]
   ],
   "columns": [
    "cf:Curriculum ID",
    "subject",
    "status",
    "cf:Assessment Score"
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
      "tracker:Epic+Phase+Module"
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
   "name": "Instructor: progress by phase",
   "roles": "staff",
   "filters": [
    [
     "tracker_id",
     "!",
     [
      "tracker:Epic+Phase+Module"
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
   "name": "Instructor: phase completion by student",
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
      "tracker:Phase"
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
      "LAB-001"
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
   "name": "Instructor: assessment scores",
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
      "tracker:Assessment+Project+Capstone"
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
   "text": "# PostgreSQL Database Engineering & Development\n\nJob-oriented PostgreSQL programme combining administration and development: SQL, PL/pgSQL, design, performance, security, backup and recovery, replication, high availability, monitoring, automation, DevOps and cloud, across 20 phases ending in an enterprise database platform capstone. Every topic follows Concept -> Implementation -> Lab -> Troubleshooting -> Performance -> Security -> Automation -> Assessment. One shared project; every student has a personal copy of each issue.\n\n## How to work an issue\n\n1. Open your next issue from the saved query *My next tasks*.\n2. Set the status to **In Progress** and do the steps. Log time at the end of every session.\n3. Set **Testing**, check every acceptance criterion, attach the evidence.\n4. Set **Review**. The instructor sets **Completed** or **Reopened**.\n\n## Pages\n\n- [[Lab_Environment]]\n- [[Course_Dataset]]\n- [[Workflow_and_Statuses]]\n- [[Assessment_and_Grading]]\n- [[Evidence_Standards]]\n- [[Troubleshooting_Report]]\n- [[Portfolio_Projects]]\n- [[Dashboard_Guide]]\n- [[Skill_Matrix]]\n- [[Tool_Matrix]]\n- [[Module_Index]]"
  },
  {
   "title": "Lab_Environment",
   "text": "# Lab environment\n\nPrimary labs use PostgreSQL 18. Versions 15 to 18 are in scope; check the current stable release before building the lab and use it if newer.\n\n| System | Minimum size | Purpose |\n|---|---|---|\n| pg1, pg2, pg3 (database servers) | 2 vCPU / 4 GB / 60 GB each | Single server labs, replication pair, three-node Patroni cluster; mix Debian and RHEL families |\n| Proxy and pooler host | 1 vCPU / 2 GB / 20 GB | HAProxy and PgBouncer (may share the database nodes in a small lab) |\n| etcd | On the three database nodes | Distributed configuration store for Patroni |\n| Monitoring host | 4 vCPU / 8 GB / 100 GB | Prometheus, Grafana, Alertmanager, Loki or OpenSearch, Zabbix |\n| Security host | 4 vCPU / 8 GB / 100 GB | Wazuh and OpenBao (phases 11 and 19) |\n| Automation host | 2 vCPU / 4 GB / 40 GB | Ansible, Terraform, Python, Git, CI runner |\n| Backup repository | 1 vCPU / 2 GB / 100 GB | pgBackRest repository and WAL archive, DR site server |\n| Kubernetes lab cluster | 3 nodes, 2 vCPU / 4 GB each | CloudNativePG (phase 18) |\n| Cloud accounts | Trial or low-cost with a budget alert | AWS, Azure and Google Cloud labs; delete resources after each lab |",
   "parent": "Wiki"
  },
  {
   "title": "Course_Dataset",
   "text": "# Course dataset and final lab\n\n## Final enterprise lab\n```\n                Applications\n                     |\n                  HAProxy\n                     |\n                 PgBouncer\n                     |\n            +--------+--------+\n            |                 |\n         Primary  --WAL-->  Read replica      (Patroni + etcd)\n            |\n         Backups -> PITR\n            |\n   Prometheus + Grafana + Loki\n            |\n     Wazuh + OpenBao          (built and operated with Ansible)\n```\n## Course dataset (schema shop)\n\n| Table | Content |\n|---|---|\n| customers | People and companies that order |\n| products | Catalogue with categories and prices |\n| orders | Order header with status and timestamps |\n| order_items | Lines of each order |\n| payments | Payments per order |\n| events | Time-series application events with a JSONB payload |\n\nGenerate at a scale of about ten million events so that plans, vacuum and partitioning behave realistically.",
   "parent": "Wiki"
  },
  {
   "title": "Workflow_and_Statuses",
   "text": "# Workflow and statuses\n\n| Status | Meaning |\n|---|---|\n| New | Template or unassigned |\n| Assigned | Belongs to a student, not started |\n| In Progress | Being worked on |\n| Blocked | Cannot continue; a note states the blocker |\n| Testing | Steps done; student checks the acceptance criteria and collects evidence |\n| Review | Submitted to the instructor |\n| Completed | Approved by the instructor |\n| Reopened | Changes requested |\n| Rejected | Waived or not applicable (instructor only) |\n\nPrerequisites are *blocked by* relations: an issue cannot be closed while its blocker is open.",
   "parent": "Wiki"
  },
  {
   "title": "Assessment_and_Grading",
   "text": "# Assessment and grading\n\n| Element | Covers |\n|---|---|\n| Theory assessments | MCQ, SQL questions, architecture questions, DBA questions |\n| Practical assessments | SQL development, database design, performance optimization, backup and restore, replication, HA, security, troubleshooting |\n| Engineering assessments | Architecture design, capacity planning, disaster recovery, production incident response |\n| Projects | 7 performance projects, 6 security projects, 10 portfolio projects and the other module projects, each scored 0-100 |\n| Capstone | CAP issues and the final assessment, scored 0-100 against the rubric |\n\nPass mark 70. Programme grade: phase assessments 30 %, projects 30 %, capstone 40 %. A student is not complete by theory alone: every phase gate requires its labs and troubleshooting cases, and the programme requires the projects and the capstone.",
   "parent": "Wiki"
  },
  {
   "title": "Evidence_Standards",
   "text": "# Evidence standards\n\n| Evidence | Minimum content |\n|---|---|\n| Notes | Own words, one page, diagrams where useful |\n| SQL script in repository | Runnable script with a comment header, committed |\n| Configuration file in repository | The changed file or include, with a reason per setting |\n| Screenshot + command output | Shows server name and the result; text output pasted as text |\n| Before and after measurements | Plans or metrics before and after, same workload, with the change stated |\n| Root cause report | Problem, evidence, diagnosis, root cause, fix, validation, prevention |\n| Written deliverable | Document attached or linked |\n| Repository link | Commit link with README, code or playbook, and a run log |\n| Repository link + documentation | Repository plus design, configuration, test results |\n| Scored result | Score and feedback recorded by the instructor |",
   "parent": "Wiki"
  },
  {
   "title": "Troubleshooting_Report",
   "text": "# Troubleshooting report\n\nEvery troubleshooting issue is closed with these seven sections:\n\n1. **Problem** - what was observed and by whom\n2. **Evidence** - logs, views and outputs collected\n3. **Diagnosis** - how the evidence was read\n4. **Root cause** - the single underlying cause\n5. **Fix** - the change made\n6. **Validation** - tests showing it works\n7. **Prevention** - what stops it happening again\n\nRead the server log first. Collect evidence before changing anything.",
   "parent": "Wiki"
  },
  {
   "title": "Portfolio_Projects",
   "text": "# Portfolio projects\n\n1. PROJECT-011 PostgreSQL Backup & PITR System\n2. PROJECT-015 PostgreSQL HA Cluster\n3. PROJECT-018 PostgreSQL Performance Lab\n4. PROJECT-020 PostgreSQL Monitoring Platform\n5. PROJECT-021 PostgreSQL Automation with Ansible\n6. PROJECT-022 PostgreSQL + pgvector + RAG application\n7. PROJECT-023 PostgreSQL + PostgREST + RLS multi-tenant application\n8. PROJECT-025 PostgreSQL Migration Project\n9. PROJECT-028 PostgreSQL Security Platform\n10. Enterprise PostgreSQL Platform (the capstone, CAP issues)",
   "parent": "Wiki"
  },
  {
   "title": "Dashboard_Guide",
   "text": "# Dashboard guide\n\nThe dashboard is the set of saved queries in the issue list sidebar. Add them to *My page* as custom query blocks.\n\n| Section | Saved query |\n|---|---|\n| Course progress | Dashboard: overall completion; phase completion; module completion; labs completed; assessment completion |\n| DBA skills | Dashboard: DBA skills (Skill Track = DBA, grouped by category: Installation, Configuration, Backup, Recovery, Replication, High Availability, Security, Performance, ...) |\n| Developer skills | Dashboard: Developer skills (SQL, Advanced SQL, PL/pgSQL, Triggers, JSONB, APIs, pgvector, Database Design, ...) |\n| Engineering skills | Dashboard: Engineering skills (Automation, Ansible, CI/CD, IaC, Cloud, Kubernetes, Observability, ...) |\n| Projects | Dashboard: projects completed; troubleshooting cases; capstone status; My portfolio projects |\n\nFor % done to follow the status, set *Administration > Settings > Issue tracking > Calculate the issue done ratio* to *Use the issue status* (global setting).",
   "parent": "Wiki"
  },
  {
   "title": "Skill_Matrix",
   "text": "# Skill matrix\n\n| Database technology | Level | Modules | Tasks | Hours |\n|---|---|---|---|---|\n| Linux | Level 1 - Foundation & Development | MOD-01, MOD-02, MOD-03 | 13 | 36 |\n| Architecture | Level 1 - Foundation & Development | MOD-04, MOD-06 | 6 | 18 |\n| Installation | Level 1 - Foundation & Development | MOD-05 | 6 | 15 |\n| Configuration | Level 1 - Foundation & Development | MOD-07 | 7 | 20 |\n| SQL | Level 1 - Foundation & Development | MOD-08, MOD-09, MOD-10, MOD-18 | 14 | 42 |\n| Advanced SQL | Level 1 - Foundation & Development | MOD-11, MOD-12, MOD-14 | 8 | 25 |\n| JSONB | Level 1 - Foundation & Development | MOD-13 | 3 | 9 |\n| Database Design | Level 1 - Foundation & Development | MOD-15 | 7 | 26 |\n| PL/pgSQL | Level 1 - Foundation & Development | MOD-16 | 5 | 21 |\n| Triggers | Level 1 - Foundation & Development | MOD-17 | 3 | 11 |\n| Extensions | Level 1 - Foundation & Development | MOD-19 | 5 | 13 |\n| SQL | Level 2 - Senior PostgreSQL Engineering | MOD-20 | 3 | 9 |\n| Indexing | Level 1 - Foundation & Development | MOD-21 | 4 | 13 |\n| Query Optimization | Level 2 - Senior PostgreSQL Engineering | MOD-22, MOD-23 | 40 | 62 |\n| Transactions & MVCC | Level 2 - Senior PostgreSQL Engineering | MOD-24, MOD-25 | 12 | 32 |\n| Vacuum | Level 2 - Senior PostgreSQL Engineering | MOD-26, MOD-27 | 12 | 34 |\n| Partitioning | Level 2 - Senior PostgreSQL Engineering | MOD-28 | 4 | 15 |\n| Partitioning | Level 3 - Enterprise PostgreSQL | MOD-29 | 5 | 17 |\n| Security | Level 2 - Senior PostgreSQL Engineering | MOD-30, MOD-31, MOD-32, MOD-33 | 16 | 58 |\n| Backup | Level 1 - Foundation & Development | MOD-34 | 5 | 12 |\n| Recovery | Level 2 - Senior PostgreSQL Engineering | MOD-35 | 7 | 24 |\n| Recovery | Level 3 - Enterprise PostgreSQL | MOD-36 | 4 | 19 |\n| Replication | Level 2 - Senior PostgreSQL Engineering | MOD-37, MOD-38 | 17 | 56 |\n| High Availability | Level 2 - Senior PostgreSQL Engineering | MOD-39, MOD-40 | 8 | 26 |\n| High Availability | Level 3 - Enterprise PostgreSQL | MOD-41, MOD-63, MOD-64 | 25 | 133 |\n| Performance | Level 2 - Senior PostgreSQL Engineering | MOD-42, MOD-43 | 19 | 70 |\n| Monitoring | Level 2 - Senior PostgreSQL Engineering | MOD-44, MOD-45 | 7 | 23 |\n| Observability | Level 3 - Enterprise PostgreSQL | MOD-46 | 3 | 15 |\n| Reliability | Level 3 - Enterprise PostgreSQL | MOD-47 | 6 | 19 |\n| Automation | Level 2 - Senior PostgreSQL Engineering | MOD-48 | 3 | 11 |\n| Ansible | Level 2 - Senior PostgreSQL Engineering | MOD-49 | 4 | 20 |\n| IaC | Level 3 - Enterprise PostgreSQL | MOD-50 | 2 | 7 |\n| CI/CD | Level 3 - Enterprise PostgreSQL | MOD-51 | 7 | 26 |\n| Cloud | Level 3 - Enterprise PostgreSQL | MOD-52 | 6 | 20 |\n| Kubernetes | Level 3 - Enterprise PostgreSQL | MOD-53 | 4 | 14 |\n| pgvector | Level 3 - Enterprise PostgreSQL | MOD-54 | 4 | 20 |\n| Extensions | Level 3 - Enterprise PostgreSQL | MOD-55 | 1 | 4 |\n| APIs | Level 3 - Enterprise PostgreSQL | MOD-56, MOD-57, MOD-58 | 8 | 37 |\n| Migration | Level 3 - Enterprise PostgreSQL | MOD-59 | 3 | 17 |\n| Scaling | Level 3 - Enterprise PostgreSQL | MOD-60 | 3 | 13 |\n| Security | Level 3 - Enterprise PostgreSQL | MOD-61 | 4 | 23 |\n| Troubleshooting | Level 3 - Enterprise PostgreSQL | MOD-62 | 12 | 30 |\n| Career | Level 3 - Enterprise PostgreSQL | MOD-65 | 5 | 19 |",
   "parent": "Wiki"
  },
  {
   "title": "Tool_Matrix",
   "text": "# Tool matrix\n\n| Tool | Modules | Hours in those modules |\n|---|---|---|\n| Alertmanager | MOD-45 | 17 |\n| Ansible | MOD-49, MOD-50, MOD-63, MOD-64 | 119 |\n| AWS | MOD-52 | 20 |\n| Azure | MOD-52 | 20 |\n| Bash | MOD-48 | 11 |\n| btree_gist | MOD-19 | 13 |\n| citext | MOD-19 | 13 |\n| CloudNativePG | MOD-53 | 14 |\n| community.postgresql | MOD-49 | 20 |\n| COPY | MOD-29, MOD-34 | 29 |\n| curl | MOD-56 | 16 |\n| df | MOD-03 | 14 |\n| dmesg | MOD-02 | 15 |\n| draw.io | MOD-15, MOD-60 | 39 |\n| du | MOD-03 | 14 |\n| etcd | MOD-41, MOD-63, MOD-64 | 133 |\n| file_fdw | MOD-19 | 13 |\n| fio | MOD-03, MOD-43 | 39 |\n| Flyway | MOD-51 | 26 |\n| free | MOD-02 | 15 |\n| Git | MOD-01, MOD-20, MOD-48, MOD-49, MOD-50, MOD-51, MOD-65 | 99 |\n| GitHub | MOD-51 | 26 |\n| GitLab | MOD-51 | 26 |\n| Google Cloud | MOD-52 | 20 |\n| Grafana | MOD-33, MOD-45, MOD-46, MOD-47, MOD-61, MOD-63, MOD-64 | 180 |\n| Grafana Alloy | MOD-46 | 15 |\n| HAProxy | MOD-40, MOD-41, MOD-60, MOD-63, MOD-64 | 152 |\n| htop | MOD-02 | 15 |\n| iostat | MOD-03, MOD-43 | 39 |\n| Jenkins | MOD-51 | 26 |\n| journalctl | MOD-02, MOD-62 | 45 |\n| kubectl | MOD-53 | 14 |\n| Liquibase | MOD-51 | 26 |\n| Loki | MOD-33, MOD-46, MOD-61, MOD-63, MOD-64 | 144 |\n| lsblk | MOD-03 | 14 |\n| lsof | MOD-02 | 15 |\n| OpenBao | MOD-61, MOD-63, MOD-64 | 115 |\n| OpenSearch | MOD-33, MOD-46, MOD-61 | 52 |\n| OpenSSL | MOD-31 | 13 |\n| pageinspect | MOD-25 | 12 |\n| Patroni | MOD-41, MOD-63, MOD-64 | 133 |\n| pg_basebackup | MOD-35, MOD-37 | 57 |\n| pg_dump | MOD-34, MOD-59 | 29 |\n| pg_dumpall | MOD-34 | 12 |\n| pg_locks | MOD-24, MOD-42 | 65 |\n| pg_restore | MOD-34 | 12 |\n| pg_stat_activity | MOD-24, MOD-42, MOD-62 | 95 |\n| pg_stat_database | MOD-42 | 45 |\n| pg_stat_statements | MOD-19, MOD-23, MOD-42 | 106 |\n| pg_stat_user_indexes | MOD-42 | 45 |\n| pg_stat_user_tables | MOD-26, MOD-42 | 71 |\n| pg_trgm | MOD-19 | 13 |\n| pgaudit | MOD-33 | 14 |\n| pgBackRest | MOD-35, MOD-36, MOD-64 | 119 |\n| pgBadger | MOD-44 | 6 |\n| pgbench | MOD-39, MOD-43 | 45 |\n| PgBouncer | MOD-39, MOD-41, MOD-57, MOD-60, MOD-63, MOD-64 | 173 |\n| pgcrypto | MOD-19, MOD-31 | 26 |\n| pgloader | MOD-59 | 17 |\n| pgstattuple | MOD-26 | 26 |\n| pgTAP | MOD-51 | 26 |\n| pgvector | MOD-54 | 20 |\n| PostGIS | MOD-55 | 4 |\n| postgres_exporter | MOD-45 | 17 |\n| postgres_fdw | MOD-19 | 13 |\n| PostgreSQL | MOD-05, MOD-06, MOD-07, MOD-08, MOD-09, MOD-10, MOD-11, MOD-12, MOD-13, MOD-14, MOD-15, MOD-16, MOD-17, MOD-18, MOD-20, MOD-21, MOD-22, MOD-23, MOD-24, MOD-25, MOD-26, MOD-27, MOD-28, MOD-29, MOD-30, MOD-31, MOD-32, MOD-33, MOD-35, MOD-36, MOD-37, MOD-38, MOD-39, MOD-40, MOD-41, MOD-42, MOD-43, MOD-44, MOD-52, MOD-53, MOD-54, MOD-55, MOD-56, MOD-57, MOD-58, MOD-59, MOD-62, MOD-63, MOD-64 | 898 |\n| PostgREST | MOD-56, MOD-58 | 30 |\n| Prometheus | MOD-45, MOD-47, MOD-61, MOD-63, MOD-64 | 151 |\n| ps | MOD-02, MOD-06 | 28 |\n| psql | MOD-05, MOD-06, MOD-07, MOD-08, MOD-09, MOD-10, MOD-11, MOD-12, MOD-13, MOD-14, MOD-16, MOD-17, MOD-18, MOD-21, MOD-22, MOD-23, MOD-24, MOD-25, MOD-26, MOD-27, MOD-28, MOD-29, MOD-30, MOD-32, MOD-34, MOD-37, MOD-38, MOD-48, MOD-62 | 469 |\n| Python | MOD-48, MOD-54, MOD-57, MOD-58 | 52 |\n| sar | MOD-02 | 15 |\n| ss | MOD-02 | 15 |\n| SSH | MOD-01 | 7 |\n| strace | MOD-02 | 15 |\n| Terraform | MOD-50 | 7 |\n| top | MOD-02 | 15 |\n| uuid-ossp | MOD-19 | 13 |\n| Vector | MOD-46 | 15 |\n| vmstat | MOD-02, MOD-43 | 40 |\n| Wazuh | MOD-33, MOD-61, MOD-63 | 53 |\n| Zabbix | MOD-45 | 17 |",
   "parent": "Wiki"
  },
  {
   "title": "Module_Index",
   "text": "# Module index\n\n## Phase 01 - Linux & Database Fundamentals\n\n### MOD-01 Lab Environment\n\nTopics: Lab servers; Virtual machines; Course dataset; Repository; Naming and addressing\n\n- THY-001 Lab design and the course dataset (Theory, 2 h)\n- LAB-001 Build the database lab servers (Lab, 4 h)\n- DOC-001 Lab inventory (Documentation, 1 h)\n\n### MOD-02 Linux for PostgreSQL: Processes, Memory and CPU\n\nTopics: Linux filesystem; Processes; Threads; Memory; CPU; Networking; systemd; Services; Users; Groups; Permissions; sudo; SSH; SELinux; AppArmor; ulimit; Kernel parameters\n\n- THY-002 Processes, memory and the page cache for database engineers (Theory, 3 h)\n- LAB-002 Inspect a running system: ps, top, htop, vmstat, sar, free (Lab, 3 h)\n- LAB-003 Users, permissions, sudo, systemd and journalctl (Lab, 3 h)\n- LAB-004 Kernel parameters, ulimit and huge pages (Lab, 3 h)\n- LAB-005 Networking and sockets: ss, lsof, strace, dmesg (Lab, 3 h)\n\n### MOD-03 Linux Storage for Databases\n\nTopics: Disk; I/O; Filesystems; LVM; RAID; Storage performance\n\n- THY-003 Disks, RAID levels, filesystems and I/O behaviour (Theory, 3 h)\n- LAB-006 LVM, filesystems and mount options (Lab, 4 h)\n- LAB-007 Measure storage: df, du, lsblk, iostat and fio (Lab, 3 h)\n- TSH-001 Scenario 01: disk full on the data volume (Troubleshooting, 2 h)\n- TSH-002 Scenario 02: server slow because of memory pressure and swap (Troubleshooting, 2 h)\n\n### MOD-04 Database Fundamentals\n\nTopics: Relational model; Tables, rows and columns; Keys; SQL; ACID; OLTP and OLAP; Client and server; The database lifecycle from design to recovery\n\n- THY-004 Relational model, ACID and the database lifecycle (Theory, 3 h)\n- ASM-001 Phase 01 assessment: Linux for PostgreSQL (Assessment, 2 h)\n\n## Phase 02 - PostgreSQL Architecture\n\n### MOD-05 Installation\n\nTopics: Installation on Ubuntu, Debian and RHEL or AlmaLinux; Windows concepts; PostgreSQL 15, 16, 17 and 18; Repository installation; Package installation; Source compilation concepts; Cluster initialization; Service management; Port configuration; Data directory; Tablespaces; Authentication\n\n- THY-005 Versions, support policy and installation methods (Theory, 2 h)\n- LAB-008 Install PostgreSQL (Lab, 4 h)\n- LAB-009 Cluster initialization, data directory and a second cluster (Lab, 3 h)\n- LAB-010 Build from source (concepts lab) (Lab, 2 h)\n- TSH-003 Scenario 03: PostgreSQL will not start (Troubleshooting, 2 h)\n- TSH-004 Scenario 04: port unavailable (Troubleshooting, 2 h)\n\n### MOD-06 PostgreSQL Architecture\n\nTopics: PostgreSQL server architecture; Postmaster; Backend processes; Background processes; Shared memory; Shared buffers; WAL; WAL writer; Checkpointer; Background writer; Autovacuum; Statistics collector concepts; Client/server architecture; Database; Schema; Table; Index; Tablespace; Query lifecycle: parser, rewriter, planner, executor, storage, WAL, commit\n\n- THY-006 Process and memory architecture (Theory, 4 h)\n- THY-007 The life of a query: parser to commit (Theory, 3 h)\n- LAB-011 See the architecture on a live server (Lab, 3 h)\n- LAB-012 Create Database & Schema (Lab, 3 h)\n\n### MOD-07 PostgreSQL Configuration\n\nTopics: postgresql.conf; pg_hba.conf; pg_ident.conf; shared_buffers; work_mem; maintenance_work_mem; effective_cache_size; max_connections; wal_buffers; checkpoint_timeout; checkpoint_completion_target; max_wal_size; min_wal_size; random_page_cost; effective_io_concurrency; max_worker_processes; max_parallel_workers; max_parallel_workers_per_gather; autovacuum settings; Tuning by workload\n\n- THY-008 Configuration files, contexts and precedence (Theory, 3 h)\n- CFG-001 Configure PostgreSQL (Configuration, 4 h)\n- CFG-002 Client authentication with pg_hba.conf (Configuration, 3 h)\n- ASG-001 Tuning by workload, not by copy (Assignment, 3 h)\n- TSH-005 Scenario 05: connection refused (Troubleshooting, 2 h)\n- TSH-006 Scenario 06: authentication failure after a pg_hba.conf change (Troubleshooting, 2 h)\n- ASM-002 Phase 02 assessment: install and configure (Assessment, 3 h)\n\n## Phase 03 - SQL Fundamentals\n\n### MOD-08 Data Types, Tables and Constraints\n\nTopics: Integer; Numeric; Decimal; Boolean; Text; VARCHAR; CHAR; Date; Time; Timestamp; Timestamp with time zone; Interval; UUID; JSON; JSONB; Arrays; ENUM; Composite types; Range types; Network types; Geometric types; PRIMARY KEY; FOREIGN KEY; UNIQUE; NOT NULL; CHECK; EXCLUDE; DEFERRABLE constraints; Referential integrity\n\n- THY-009 PostgreSQL data types and how to choose them (Theory, 3 h)\n- SQL-001 Create the course dataset schema (SQL Development, 4 h)\n- SQL-002 Constraints: referential integrity, EXCLUDE and DEFERRABLE (SQL Development, 3 h)\n- SQL-003 Special types in practice: UUID, enum, arrays, ranges, network (SQL Development, 3 h)\n\n### MOD-09 SQL Fundamentals\n\nTopics: SELECT; INSERT; UPDATE; DELETE; WHERE; ORDER BY; GROUP BY; HAVING; LIMIT; OFFSET; DISTINCT; CASE; COALESCE; NULL handling; Functions; Operators; Aliases\n\n- LAB-013 SQL Fundamentals (Lab, 4 h)\n- SQL-004 INSERT, UPDATE, DELETE, RETURNING, upsert and MERGE (SQL Development, 3 h)\n- SQL-005 NULL handling, CASE and COALESCE (SQL Development, 2 h)\n- SQL-006 GROUP BY, HAVING and aggregates (SQL Development, 3 h)\n\n### MOD-10 Joins\n\nTopics: INNER JOIN; LEFT JOIN; RIGHT JOIN; FULL JOIN; CROSS JOIN; SELF JOIN; LATERAL JOIN\n\n- THY-010 Join types and join logic (Theory, 2 h)\n- SQL-007 Inner, left, right, full and cross joins on the business dataset (SQL Development, 4 h)\n- LAB-014 Advanced Joins (Lab, 3 h)\n- ASM-003 Phase 03 assessment: SQL practical (Assessment, 3 h)\n\n## Phase 04 - Advanced SQL\n\n### MOD-11 Subqueries and CTEs\n\nTopics: Subqueries; Correlated subqueries; CTE; Recursive CTE\n\n- SQL-008 Subqueries and correlated subqueries (SQL Development, 3 h)\n- LAB-015 CTE & Recursive Queries (Lab, 4 h)\n\n### MOD-12 Window Functions and Aggregation\n\nTopics: Window functions; Ranking; Aggregation; FILTER\n\n- LAB-016 Window Functions (Lab, 4 h)\n- SQL-009 Analytic reporting: cohorts, percentiles and gaps (SQL Development, 3 h)\n\n### MOD-13 JSON and JSONB\n\nTopics: JSON; JSONB; Operators; JSON path; Indexing; GIN; JSON queries; Hybrid relational/document design\n\n- THY-011 JSON versus JSONB and hybrid design (Theory, 2 h)\n- SQL-010 JSONB operators, functions and JSON path (SQL Development, 4 h)\n- SQL-011 Index and constrain JSONB (SQL Development, 3 h)\n\n### MOD-14 Arrays, Text, Regex, Date/Time and Ranges\n\nTopics: ARRAY; Regex; String functions; Date/time; Range types\n\n- SQL-012 Arrays and string functions (SQL Development, 3 h)\n- SQL-013 Regular expressions (SQL Development, 2 h)\n- SQL-014 Date/time and range types (SQL Development, 3 h)\n- ASM-004 Phase 04 assessment: advanced SQL practical (Assessment, 3 h)\n\n## Phase 05 - Database Design\n\n### MOD-15 Database Design\n\nTopics: Requirements analysis; Entities; Relationships; ER diagrams; Normalization; 1NF; 2NF; 3NF; BCNF; Denormalization; OLTP; OLAP; Data modeling\n\n- THY-012 Requirements, entities, relationships and ER diagrams (Theory, 3 h)\n- THY-013 Normalization: 1NF, 2NF, 3NF and BCNF (Theory, 3 h)\n- ASG-002 Normalize a real dataset (Assignment, 4 h)\n- THY-014 Denormalization, OLTP and OLAP modelling (Theory, 3 h)\n- ASG-003 Naming conventions and SQL standards (Assignment, 2 h)\n- PROJECT-001 Database design project: booking platform (Project, 8 h)\n- ASM-005 Phase 05 assessment: database design (Assessment, 3 h)\n\n## Phase 06 - PostgreSQL Development\n\n### MOD-16 PL/pgSQL\n\nTopics: Functions; Procedures; Variables; IF; CASE; LOOP; FOR; WHILE; Exceptions; Cursors; Dynamic SQL; Record; Row types\n\n- THY-015 Functions versus procedures, volatility and security (Theory, 3 h)\n- LAB-017 PL/pgSQL (Lab, 4 h)\n- SQL-015 Exceptions, diagnostics and error design (SQL Development, 3 h)\n- SQL-016 Cursors and dynamic SQL (SQL Development, 3 h)\n- PROJECT-002 Database programming project: order processing API in the database (Project, 8 h)\n\n### MOD-17 Triggers\n\nTopics: BEFORE; AFTER; INSTEAD OF; Row-level; Statement-level; Trigger functions; Audit triggers; Validation; History tracking\n\n- THY-016 Trigger timing, level and execution order (Theory, 2 h)\n- LAB-018 Triggers (Lab, 3 h)\n- PROJECT-003 Audit logging project (Project, 6 h)\n\n### MOD-18 Views and Materialized Views\n\nTopics: Views; Materialized views; Refresh; Concurrent refresh; Materialized-view optimization\n\n- SQL-017 Views, updatable views and security barrier (SQL Development, 2 h)\n- SQL-018 Materialized views and concurrent refresh (SQL Development, 3 h)\n\n### MOD-19 PostgreSQL Extensions\n\nTopics: pgcrypto; citext; pg_trgm; btree_gist; uuid-ossp; postgres_fdw; file_fdw; pg_stat_statements; pgvector\n\n- THY-017 The extension system (Theory, 2 h)\n- LAB-019 pgcrypto, citext and uuid-ossp (Lab, 3 h)\n- LAB-020 pg_trgm and btree_gist (Lab, 3 h)\n- LAB-021 postgres_fdw and file_fdw (Lab, 3 h)\n- LAB-022 pg_stat_statements (Lab, 2 h)\n\n### MOD-20 Database Development Practices\n\nTopics: Schema design; SQL standards; Naming conventions; Migration strategy; Stored procedures; Functions; Error handling; Transaction design; Index strategy; Query review; Code review\n\n- ASG-004 Code and query review checklist (Assignment, 3 h)\n- ASG-005 Transaction design for an application feature (Assignment, 3 h)\n- ASM-006 Phase 06 assessment: database development practical (Assessment, 3 h)\n\n## Phase 07 - Indexing & Query Optimization\n\n### MOD-21 Indexing\n\nTopics: Why indexes work; B-tree; Hash; GIN; GiST; SP-GiST; BRIN; Partial indexes; Expression indexes; Covering indexes; INCLUDE; Multicolumn indexes; Index-only scans; Index bloat; When not to create an index\n\n- THY-018 How indexes work and what they cost (Theory, 3 h)\n- THY-019 Index types: B-tree, Hash, GIN, GiST, SP-GiST and BRIN (Theory, 3 h)\n- LAB-023 Indexing (Lab, 4 h)\n- ASG-006 When not to index: audit of unused and duplicate indexes (Assignment, 3 h)\n\n### MOD-22 Query Planning\n\nTopics: EXPLAIN; EXPLAIN ANALYZE; BUFFERS; VERBOSE; COST; Sequential scan; Index scan; Bitmap scan; Nested loop; Hash join; Merge join; Sort; Aggregate; Parallel query; Planner statistics; Cardinality estimation\n\n- THY-020 Reading plans: costs, rows, nodes and buffers (Theory, 4 h)\n- LAB-024 EXPLAIN ANALYZE (Lab, 4 h)\n- THY-021 Planner statistics and cardinality estimation (Theory, 3 h)\n- LAB-025 Fix misestimates with ANALYZE and extended statistics (Lab, 3 h)\n\n### MOD-23 Query Optimization Labs\n\nTopics: Thirty query optimization labs; Method: measure, read the plan, change one thing, measure again\n\n- LAB-026 Query Optimization (Lab, 3 h)\n- PERF-001 Optimization lab 01: missing index on a filter (Performance, 1 h)\n- PERF-002 Optimization lab 02: multicolumn index column order (Performance, 1 h)\n- PERF-003 Optimization lab 03: function on an indexed column (Performance, 1 h)\n- PERF-004 Optimization lab 04: implicit cast prevents index use (Performance, 1 h)\n- PERF-005 Optimization lab 05: leading wildcard LIKE (Performance, 1 h)\n- PERF-006 Optimization lab 06: OR across columns (Performance, 1 h)\n- PERF-007 Optimization lab 07: NOT IN with NULLs (Performance, 1 h)\n- PERF-008 Optimization lab 08: correlated subquery per row (Performance, 1 h)\n- PERF-009 Optimization lab 09: SELECT star blocks index-only scan (Performance, 1 h)\n- PERF-010 Optimization lab 10: deep OFFSET pagination (Performance, 1 h)\n- PERF-011 Optimization lab 11: ORDER BY with LIMIT needs a matching index (Performance, 1 h)\n- PERF-012 Optimization lab 12: count of a large table (Performance, 1 h)\n- PERF-013 Optimization lab 13: sort spilling to disk (Performance, 1 h)\n- PERF-014 Optimization lab 14: hash join spilling in batches (Performance, 1 h)\n- PERF-015 Optimization lab 15: nested loop on a row misestimate (Performance, 1 h)\n- PERF-016 Optimization lab 16: stale statistics after a bulk load (Performance, 1 h)\n- PERF-017 Optimization lab 17: correlated columns (Performance, 1 h)\n- PERF-018 Optimization lab 18: partial index for a hot subset (Performance, 1 h)\n- PERF-019 Optimization lab 19: JSONB containment search (Performance, 1 h)\n- PERF-020 Optimization lab 20: array membership search (Performance, 1 h)\n- PERF-021 Optimization lab 21: range overlap search (Performance, 1 h)\n- PERF-022 Optimization lab 22: time-series scan on a huge table (Performance, 1 h)\n- PERF-023 Optimization lab 23: CTE acting as a fence (Performance, 1 h)\n- PERF-024 Optimization lab 24: DISTINCT hiding a bad join (Performance, 1 h)\n- PERF-025 Optimization lab 25: join order and missing foreign key index (Performance, 1 h)\n- PERF-026 Optimization lab 26: parallel query not used (Performance, 1 h)\n- PERF-027 Optimization lab 27: generic plan for a prepared statement (Performance, 1 h)\n- PERF-028 Optimization lab 28: slow UPDATE touching indexed columns (Performance, 1 h)\n- PERF-029 Optimization lab 29: slow DELETE with cascading foreign keys (Performance, 1 h)\n- PERF-030 Optimization lab 30: reporting query on a normalized schema (Performance, 1 h)\n- TSH-007 Scenario 07: slow query in production (Troubleshooting, 2 h)\n- TSH-008 Scenario 08: missing index after a deployment (Troubleshooting, 2 h)\n- TSH-009 Scenario 09: bad query plan after an upgrade or data change (Troubleshooting, 2 h)\n- PROJECT-004 Performance project 2: design an indexing strategy (Project, 6 h)\n- ASM-007 Phase 07 assessment: performance optimization practical (Assessment, 3 h)\n\n## Phase 08 - Transactions & MVCC\n\n### MOD-24 Transactions and Locking\n\nTopics: ACID; BEGIN; COMMIT; ROLLBACK; SAVEPOINT; Transaction isolation; Read Committed; Repeatable Read; Serializable; Read Uncommitted behavior; Locks; Deadlocks\n\n- THY-022 Isolation levels and anomalies (Theory, 3 h)\n- LAB-027 Transactions (Lab, 3 h)\n- THY-023 Lock modes: table locks, row locks and lock queues (Theory, 3 h)\n- LAB-028 Investigate locks with pg_locks and pg_stat_activity (Lab, 3 h)\n- TSH-010 Scenario 10: lock wait blocking the application (Troubleshooting, 2 h)\n- TSH-011 Scenario 11: deadlock (Troubleshooting, 2 h)\n- TSH-012 Scenario 12: idle-in-transaction sessions holding locks (Troubleshooting, 2 h)\n- TSH-013 Scenario 13: DDL causes an outage through the lock queue (Troubleshooting, 2 h)\n\n### MOD-25 MVCC\n\nTopics: MVCC; Tuple versions; xmin; xmax; Visibility; Transaction IDs; Snapshot; Dead tuples; Vacuum; Transaction wraparound\n\n- THY-024 MVCC: tuple versions, snapshots and visibility (Theory, 4 h)\n- LAB-029 MVCC Investigation (Lab, 4 h)\n- TSH-014 Scenario 14: table grows although the row count is stable (Troubleshooting, 2 h)\n- ASM-008 Phase 08 assessment: transactions and MVCC (Assessment, 2 h)\n\n## Phase 09 - Vacuum & Storage\n\n### MOD-26 VACUUM and Autovacuum\n\nTopics: VACUUM; VACUUM ANALYZE; VACUUM FULL; ANALYZE; Autovacuum; Dead tuples; Table bloat; Index bloat; Freeze; Transaction ID wraparound; Autovacuum tuning by workload\n\n- THY-025 What VACUUM does and does not do (Theory, 3 h)\n- LAB-030 Vacuum (Lab, 4 h)\n- THY-026 Autovacuum: triggers, workers and cost limits (Theory, 3 h)\n- LAB-031 Tune autovacuum by workload (Lab, 4 h)\n- LAB-032 Index bloat and REINDEX CONCURRENTLY (Lab, 3 h)\n- TSH-015 Scenario 15: autovacuum never finishes on a hot table (Troubleshooting, 2 h)\n- TSH-016 Scenario 16: table bloat (Troubleshooting, 2 h)\n- TSH-017 Scenario 17: index bloat (Troubleshooting, 2 h)\n- TSH-018 Scenario 18: transaction ID wraparound warning (Troubleshooting, 3 h)\n\n### MOD-27 Storage Internals and Tablespaces\n\nTopics: Pages; Heap files; TOAST; Fillfactor; Tablespaces; Relation size functions\n\n- THY-027 Pages, heap files, TOAST and fillfactor (Theory, 3 h)\n- LAB-033 Measure and manage relation storage (Lab, 3 h)\n- ASM-009 Phase 09 assessment: vacuum and storage (Assessment, 2 h)\n\n## Phase 10 - Partitioning\n\n### MOD-28 Table Partitioning\n\nTopics: Range partitioning; List partitioning; Hash partitioning; Partition pruning; Partition maintenance; Partition indexes; Partition constraints; Time-based partitioning; Large-table management\n\n- THY-028 Partitioning concepts and when to use them (Theory, 3 h)\n- LAB-034 Partitioning (Lab, 4 h)\n- LAB-035 Partition maintenance: attach, detach and retention (Lab, 4 h)\n- LAB-036 Convert a large table to partitioned with little downtime (Lab, 4 h)\n\n### MOD-29 Large Database Engineering\n\nTopics: Large tables; Index management; Vacuum strategy; Archiving; Data retention; Cold data; Hot data; Storage architecture; Tablespaces; Bulk loading; COPY; Parallel operations\n\n- LAB-037 Bulk loading with COPY and parallel operations (Lab, 4 h)\n- ASG-007 Data retention, archiving and hot and cold storage design (Assignment, 3 h)\n- PROJECT-005 Performance project 5: optimize a large partitioned table (Project, 6 h)\n- TSH-019 Scenario 19: queries scan every partition (Troubleshooting, 2 h)\n- ASM-010 Phase 10 assessment: partitioning (Assessment, 2 h)\n\n## Phase 11 - PostgreSQL Security\n\n### MOD-30 Authentication and Roles\n\nTopics: Authentication; Authorization; Roles; Users; Groups; GRANT; REVOKE; Default privileges; pg_hba.conf; Password authentication; SCRAM\n\n- THY-029 Roles, privileges and ownership (Theory, 3 h)\n- LAB-038 PostgreSQL Security (Lab, 4 h)\n- SEC-001 SCRAM passwords, password policy and connection limits (Security, 2 h)\n- PROJECT-006 Security project 2: role and privilege architecture (Project, 5 h)\n- TSH-020 Scenario 20: permission denied after a deployment (Troubleshooting, 2 h)\n\n### MOD-31 TLS, Certificates and Encryption\n\nTopics: SSL/TLS; Certificate authentication; Encryption; Secrets management\n\n- SEC-002 TLS for client connections (Security, 3 h)\n- SEC-003 Certificate authentication (Security, 3 h)\n- THY-030 Encryption at rest and in the application (Theory, 2 h)\n- PROJECT-007 Security project 1: secure PostgreSQL installation (Project, 5 h)\n\n### MOD-32 Row Level Security\n\nTopics: RLS; Policies; USING; WITH CHECK; Multi-tenant database security; Tenant isolation\n\n- THY-031 RLS: policies, USING and WITH CHECK (Theory, 3 h)\n- SEC-004 Tenant isolation with RLS (Security, 4 h)\n- PROJECT-008 Security project 3: multi-tenant SaaS database with RLS (Project, 8 h)\n\n### MOD-33 Database Auditing\n\nTopics: PostgreSQL logging; Audit logging; pgaudit; Login auditing; DDL auditing; DML auditing; Privilege monitoring; Integration with Wazuh, Grafana, Loki and OpenSearch\n\n- SEC-005 Login, DDL and DML auditing with pgaudit (Security, 4 h)\n- SEC-006 Privilege monitoring (Security, 2 h)\n- PROJECT-009 Security project 4: PostgreSQL auditing (Project, 5 h)\n- ASM-011 Phase 11 assessment: security practical (Assessment, 3 h)\n\n## Phase 12 - Backup & Recovery\n\n### MOD-34 Logical Backup\n\nTopics: Logical backup; pg_dump; pg_dumpall; pg_restore; COPY\n\n- THY-032 Logical versus physical backup (Theory, 2 h)\n- LAB-039 Backup (Lab, 4 h)\n- LAB-040 COPY for export and import (Lab, 2 h)\n- TSH-021 Scenario 21: backup failure (Troubleshooting, 2 h)\n- TSH-022 Scenario 22: restore failure (Troubleshooting, 2 h)\n\n### MOD-35 Physical Backup and PITR\n\nTopics: Physical backup; Base backups; WAL archiving; PITR; Recovery; Recovery targets; Backup validation; Backup testing\n\n- THY-033 WAL, base backups and how PITR works (Theory, 3 h)\n- LAB-041 Base backup and WAL archiving (Lab, 4 h)\n- LAB-042 PITR (Lab, 5 h)\n- LAB-043 pgBackRest: full, differential, incremental and retention (Lab, 4 h)\n- DBA-001 Backup validation and scheduled restore tests (DBA, 3 h)\n- TSH-023 Scenario 23: WAL archive is failing (Troubleshooting, 2 h)\n- TSH-024 Scenario 24: PITR failure (Troubleshooting, 3 h)\n\n### MOD-36 Disaster Recovery\n\nTopics: RPO; RTO; DR planning; Backup strategy; Recovery strategy; Multi-site DR; Cold standby; Warm standby; Hot standby; Failover; Failback\n\n- THY-034 RPO, RTO and standby types (Theory, 2 h)\n- PROJECT-010 PostgreSQL Disaster Recovery Project (Project, 8 h)\n- PROJECT-011 Portfolio: PostgreSQL Backup & PITR System (Project, 6 h)\n- ASM-012 Phase 12 assessment: backup and restore practical (Assessment, 3 h)\n\n## Phase 13 - Replication\n\n### MOD-37 Streaming Replication\n\nTopics: Streaming replication; Physical replication; Primary; Standby; WAL sender; WAL receiver; Replication slots; Synchronous replication; Asynchronous replication; Cascading replication; Hot standby\n\n- THY-035 Physical replication architecture (Theory, 3 h)\n- LAB-044 Streaming Replication (Lab, 5 h)\n- LAB-045 Synchronous replication (Lab, 3 h)\n- LAB-046 Cascading replication and delayed standby (Lab, 3 h)\n- LAB-047 Promotion, switchover and pg_rewind (Lab, 4 h)\n- TSH-025 Scenario 25: replication lag (Troubleshooting, 2 h)\n- TSH-026 Scenario 26: replication failure, standby cannot connect (Troubleshooting, 2 h)\n- TSH-027 Scenario 27: WAL growth from an inactive replication slot (Troubleshooting, 2 h)\n- TSH-028 Scenario 28: standby needs WAL that was already removed (Troubleshooting, 2 h)\n- TSH-029 Scenario 29: queries cancelled on the hot standby (Troubleshooting, 2 h)\n- PROJECT-012 Performance project 6: reduce replication lag (Project, 5 h)\n\n### MOD-38 Logical Replication\n\nTopics: Publications; Subscriptions; Logical replication slots; Initial synchronization; Conflict handling; Filtering; Replication monitoring\n\n- THY-036 Logical replication architecture and limits (Theory, 3 h)\n- LAB-048 Logical Replication (Lab, 4 h)\n- LAB-049 Row filters, column lists and conflict handling (Lab, 3 h)\n- PROJECT-013 Migration project: major version upgrade with logical replication (Project, 8 h)\n- TSH-030 Scenario 30: logical replication stopped after a schema change (Troubleshooting, 2 h)\n- ASM-013 Phase 13 assessment: replication practical (Assessment, 3 h)\n\n## Phase 14 - High Availability\n\n### MOD-39 PgBouncer\n\nTopics: Session pooling; Transaction pooling; Statement pooling; Connection limits; Authentication; Pool sizing; PostgreSQL connection management\n\n- THY-037 Why connections are expensive and how pooling helps (Theory, 3 h)\n- LAB-050 PgBouncer (Lab, 4 h)\n- LAB-051 High-connection workload lab (Lab, 4 h)\n- TSH-031 Scenario 31: too many connections (Troubleshooting, 2 h)\n- TSH-032 Scenario 32: PgBouncer issue, clients wait while the database is idle (Troubleshooting, 2 h)\n- PROJECT-014 Performance project 4: resolve connection exhaustion (Project, 5 h)\n\n### MOD-40 HAProxy\n\nTopics: TCP load balancing; PostgreSQL routing; Health checks; Read/write routing concepts; Failover; HA architecture\n\n- LAB-052 HAProxy (Lab, 4 h)\n- TSH-033 Scenario 33: HAProxy issue, traffic sent to the wrong node (Troubleshooting, 2 h)\n\n### MOD-41 Patroni and etcd\n\nTopics: HA architecture; Automatic failover; Manual failover; Leader election; Quorum; Split-brain; Fencing; Failover testing\n\n- THY-038 HA concepts: quorum, leader election, split-brain and fencing (Theory, 3 h)\n- LAB-053 etcd cluster (Lab, 3 h)\n- LAB-054 Patroni HA (Lab, 6 h)\n- LAB-055 Client routing with HAProxy and PgBouncer on Patroni (Lab, 4 h)\n- LAB-056 Failover testing (Lab, 5 h)\n- PROJECT-015 Portfolio: PostgreSQL HA Cluster (Project, 8 h)\n- TSH-034 Scenario 34: Patroni failure, no leader is elected (Troubleshooting, 3 h)\n- TSH-035 Scenario 35: failover problem, old primary will not rejoin (Troubleshooting, 3 h)\n- TSH-036 Scenario 36: split-brain suspicion (Troubleshooting, 3 h)\n- ASM-014 Phase 14 assessment: high availability practical (Assessment, 3 h)\n\n## Phase 15 - Performance Engineering\n\n### MOD-42 PostgreSQL Performance Engineering\n\nTopics: CPU; Memory; Disk I/O; Network; Locks; Connections; Query latency; WAL; Checkpoints; Vacuum; Cache hit ratio; Bloat; Slow queries\n\n- THY-039 A method for performance work (Theory, 3 h)\n- LAB-057 Statistics views tour (Lab, 4 h)\n- PERF-031 Memory tuning: shared_buffers, work_mem and cache hit ratio (Performance, 4 h)\n- PERF-032 WAL and checkpoint tuning (Performance, 4 h)\n- PERF-033 I/O tuning: random_page_cost, effective_io_concurrency and asynchronous I/O (Performance, 3 h)\n- PERF-034 Parallel query tuning (Performance, 3 h)\n- PROJECT-016 Performance project 1: optimize a slow PostgreSQL application (Project, 8 h)\n- PROJECT-017 Performance project 3: fix a high-CPU PostgreSQL server (Project, 5 h)\n- TSH-037 Scenario 37: high CPU (Troubleshooting, 2 h)\n- TSH-038 Scenario 38: high memory and OOM kill of a backend (Troubleshooting, 3 h)\n- TSH-039 Scenario 39: checkpoint problems and I/O spikes (Troubleshooting, 2 h)\n- TSH-040 Scenario 40: storage bottleneck (Troubleshooting, 2 h)\n- TSH-041 Scenario 41: temp files filling the disk (Troubleshooting, 2 h)\n\n### MOD-43 Performance Testing\n\nTopics: pgbench; sysbench concepts; EXPLAIN ANALYZE; fio; iostat; vmstat; perf concepts; Benchmarks for CPU, memory, storage, connections, queries, transactions, WAL and replication\n\n- THY-040 Benchmark design (Theory, 2 h)\n- LAB-058 Benchmarks: storage, CPU and memory (Lab, 4 h)\n- LAB-059 Benchmarks: connections, transactions, WAL and replication (Lab, 4 h)\n- PROJECT-018 Portfolio: PostgreSQL Performance Lab (Project, 6 h)\n- PROJECT-019 Performance project 7: design a high-performance PostgreSQL architecture (Project, 6 h)\n- ASM-015 Phase 15 assessment: performance engineering (Assessment, 3 h)\n\n## Phase 16 - Monitoring & Observability\n\n### MOD-44 PostgreSQL Logging\n\nTopics: log_statement; log_min_duration_statement; log_connections; log_disconnections; log_checkpoints; log_lock_waits; CSV logs; JSON logging concepts; PostgreSQL log analysis\n\n- CFG-003 Logging configuration for production (Configuration, 3 h)\n- LAB-060 Log analysis with pgBadger (Lab, 3 h)\n\n### MOD-45 PostgreSQL Monitoring\n\nTopics: Database metrics; Query metrics; Replication metrics; WAL metrics; Lock metrics; Vacuum metrics; Connection metrics; Cache metrics; Disk metrics\n\n- THY-041 What to monitor and why (Theory, 2 h)\n- LAB-061 PostgreSQL Monitoring (Lab, 5 h)\n- LAB-062 Grafana Dashboard (Lab, 5 h)\n- LAB-063 Alert rules (Lab, 3 h)\n- LAB-064 Zabbix template for PostgreSQL (Lab, 2 h)\n\n### MOD-46 Observability and Log Pipeline\n\nTopics: PostgreSQL to postgres_exporter to Prometheus to Grafana; PostgreSQL logs to Alloy or Vector to Loki or OpenSearch to Grafana; Dashboards for availability, connections, query latency, locks, WAL, replication, vacuum, disk, CPU, memory and errors\n\n- LAB-065 Ship PostgreSQL logs to Loki or OpenSearch (Lab, 4 h)\n- LAB-066 Correlate metrics and logs (Lab, 3 h)\n- PROJECT-020 Portfolio: PostgreSQL Monitoring Platform (Project, 8 h)\n\n### MOD-47 Database Reliability Engineering\n\nTopics: SLI; SLO; SLA; Error budgets; Availability; Reliability; Incident management; Capacity planning; Performance budgets; Database runbooks\n\n- THY-042 SLI, SLO, SLA and error budgets for databases (Theory, 3 h)\n- LAB-067 PostgreSQL SRE dashboards and burn-rate alerts (Lab, 4 h)\n- ASG-008 Capacity planning (Assignment, 3 h)\n- DOC-002 Database runbooks (Documentation, 4 h)\n- ASG-009 Production incident response exercise (Assignment, 3 h)\n- ASM-016 Phase 16 assessment: monitoring (Assessment, 2 h)\n\n## Phase 17 - Automation & DevOps\n\n### MOD-48 Database Automation with Bash, Python and SQL\n\nTopics: Bash; Python; SQL; PostgreSQL APIs; REST APIs; Git; Automating installation, configuration, user creation, database creation, backup, restore, monitoring, health checks, failover checks, security audits and performance reports\n\n- AUTO-001 Bash automation: backup, restore check and health check (Automation, 4 h)\n- AUTO-002 Python with psycopg: users, databases and reports (Automation, 4 h)\n- AUTO-003 Security audit and failover check automation (Automation, 3 h)\n\n### MOD-49 Ansible and PostgreSQL\n\nTopics: Inventory; Variables; Roles; Templates; Handlers; PostgreSQL modules; Secrets; Idempotency\n\n- THY-043 Ansible for database servers (Theory, 2 h)\n- LAB-068 Ansible Automation (Lab, 5 h)\n- AUTO-004 Roles for users, databases, backup and monitoring (Automation, 5 h)\n- PROJECT-021 Portfolio: PostgreSQL Automation with Ansible (Project, 8 h)\n\n### MOD-50 Infrastructure as Code\n\nTopics: Terraform; Ansible; Git; CI/CD; Infrastructure lifecycle; Configuration management\n\n- THY-044 Infrastructure lifecycle with Terraform and Ansible (Theory, 2 h)\n- LAB-069 PostgreSQL infrastructure with Terraform (Lab, 5 h)\n\n### MOD-51 Database DevOps and Testing\n\nTopics: Migration management; Schema versioning; CI/CD; Database testing; Deployment strategies; Rollbacks; Blue/green concepts; Zero-downtime migrations; Unit testing; SQL testing; Integration testing; Data validation; Performance testing; Regression testing; Migration testing; Backup testing; Recovery testing\n\n- THY-045 Schema versioning and migration tools (Theory, 3 h)\n- LAB-070 Versioned migrations in Git (Lab, 4 h)\n- LAB-071 Zero-downtime migration patterns (Lab, 4 h)\n- LAB-072 Database testing with pgTAP (Lab, 4 h)\n- LAB-073 CI/CD pipeline for database changes (Lab, 5 h)\n- ASG-010 Deployment strategies: blue/green, rollback and backup testing (Assignment, 3 h)\n- ASM-017 Phase 17 assessment: automation and DevOps (Assessment, 3 h)\n\n## Phase 18 - Cloud & Kubernetes\n\n### MOD-52 Cloud PostgreSQL\n\nTopics: AWS: RDS PostgreSQL, Aurora PostgreSQL, EC2 PostgreSQL, backup, monitoring, HA, security; Azure Database for PostgreSQL Flexible Server, networking, backup, HA; Google Cloud SQL for PostgreSQL, HA, backup, monitoring; Architecture over provider memorization\n\n- THY-046 Managed PostgreSQL architecture: what the provider does and what you still own (Theory, 3 h)\n- LAB-074 AWS: RDS for PostgreSQL (Lab, 5 h)\n- THY-047 Aurora PostgreSQL architecture (Theory, 2 h)\n- LAB-075 Azure Database for PostgreSQL Flexible Server (Lab, 4 h)\n- LAB-076 Google Cloud SQL for PostgreSQL (Lab, 3 h)\n- ASG-011 Cloud database selection and cost (Assignment, 3 h)\n\n### MOD-53 PostgreSQL on Kubernetes\n\nTopics: PostgreSQL on Kubernetes; StatefulSets; Persistent volumes; Storage classes; Secrets; ConfigMaps; Operators; HA; Backup; Restore; CloudNativePG; Zalando PostgreSQL Operator concepts\n\n- THY-048 Stateful workloads on Kubernetes and the operator pattern (Theory, 3 h)\n- LAB-077 PostgreSQL with a StatefulSet (to see the limits) (Lab, 3 h)\n- LAB-078 CloudNativePG cluster: HA, backup and restore (Lab, 6 h)\n- ASM-018 Phase 18 assessment: cloud and Kubernetes (Assessment, 2 h)\n\n## Phase 19 - Advanced PostgreSQL Engineering\n\n### MOD-54 pgvector and AI Database Engineering\n\nTopics: Embeddings; Vector data; pgvector; Vector similarity; Cosine distance; L2 distance; HNSW; IVFFlat; Hybrid search; RAG architecture; PostgreSQL and AI applications\n\n- THY-049 Embeddings, similarity and vector indexes (Theory, 3 h)\n- LAB-079 PostgreSQL + pgvector (Lab, 4 h)\n- LAB-080 Hybrid search: full-text plus vector (Lab, 3 h)\n- PROJECT-022 Portfolio: PostgreSQL + pgvector + RAG application (Project, 10 h)\n\n### MOD-55 PostGIS Fundamentals\n\nTopics: Geometry; Geography; Spatial indexes; Spatial queries; GIS data\n\n- LAB-081 PostGIS: geometry, geography, indexes and queries (Lab, 4 h)\n\n### MOD-56 PostgreSQL API Engineering\n\nTopics: REST; PostgREST; API security; Database roles; RLS; JWT; CRUD; API authorization\n\n- THY-050 PostgREST: the database as the API (Theory, 2 h)\n- LAB-082 PostgREST CRUD API with roles and JWT (Lab, 4 h)\n- PROJECT-023 Portfolio: PostgreSQL + PostgREST + RLS multi-tenant application (Project, 10 h)\n\n### MOD-57 Connection and Application Engineering\n\nTopics: Connection pooling; Application connections; Prepared statements; Transactions; Connection limits; Timeouts; Retry strategies; Idempotency; Database API design\n\n- THY-051 How applications should talk to PostgreSQL (Theory, 3 h)\n- LAB-083 Timeouts, retries and idempotency in Python (Lab, 4 h)\n\n### MOD-58 Data Engineering Integration\n\nTopics: Python; REST APIs; PostgREST; ETL; CDC; Kafka concepts; Data warehouses; BI tools\n\n- THY-052 ETL, CDC and analytics architecture (Theory, 2 h)\n- LAB-084 ETL with Python and CDC with logical decoding (Lab, 4 h)\n- PROJECT-024 PostgreSQL API + Analytics Project (Project, 8 h)\n\n### MOD-59 Migration Engineering\n\nTopics: MySQL to PostgreSQL; SQL Server to PostgreSQL; Oracle to PostgreSQL; Older PostgreSQL to newer PostgreSQL; pg_dump; Logical replication; ETL; CDC concepts; Dual-write concepts; Cutover; Rollback\n\n- THY-053 Migration methods and risks (Theory, 3 h)\n- LAB-085 pg_upgrade major version upgrade (Lab, 4 h)\n- PROJECT-025 Portfolio: PostgreSQL Migration Project (Project, 10 h)\n\n### MOD-60 PostgreSQL Scaling and Architecture\n\nTopics: Vertical scaling; Read replicas; Connection pooling; Partitioning; Caching; Query optimization; Horizontal scaling concepts; Sharding concepts; Distributed PostgreSQL concepts; Citus concepts; pgpool-II; Multi-region architecture; Design for small applications, SaaS, enterprise, multi-tenant, high-traffic websites, financial systems, ERP, CRM, analytics and AI applications\n\n- THY-054 Scaling ladder: from one server to distributed (Theory, 3 h)\n- ASG-012 Reference architectures for ten application types (Assignment, 6 h)\n- ASG-013 Multi-region architecture and disaster recovery design (Assignment, 4 h)\n\n### MOD-61 Security Integration\n\nTopics: Integration of PostgreSQL with Wazuh, Grafana, Prometheus, Loki, OpenSearch and OpenBao\n\n- LAB-086 PostgreSQL Security Monitoring (Lab, 5 h)\n- PROJECT-026 Security project 5: PostgreSQL + OpenBao secrets management (Project, 6 h)\n- PROJECT-027 Security project 6: PostgreSQL security monitoring with Wazuh (Project, 6 h)\n- PROJECT-028 Portfolio: PostgreSQL Security Platform (Project, 6 h)\n\n### MOD-62 PostgreSQL Troubleshooting\n\nTopics: Database unavailable; Connection refused; Authentication failure; Too many connections; Slow query; Lock wait; Deadlock; High CPU; High memory; Disk full; WAL growth; Replication lag; Broken replication; Autovacuum problems; Bloat; Checkpoint problems; Corruption concepts; Failover problems; Backup failure; PITR failure\n\n- THY-055 Troubleshooting method and the seven-section report (Theory, 2 h)\n- TSH-042 Scenario 42: database unavailable after a reboot (Troubleshooting, 2 h)\n- TSH-043 Scenario 43: crash recovery takes very long (Troubleshooting, 2 h)\n- TSH-044 Scenario 44: pg_wal fills the disk (Troubleshooting, 3 h)\n- TSH-045 Scenario 45: checksum failure reported (Troubleshooting, 3 h)\n- TSH-046 Scenario 46: application errors after failover (Troubleshooting, 2 h)\n- TSH-047 Scenario 47: sequence or statistics problem after an upgrade or restore (Troubleshooting, 2 h)\n- TSH-048 Scenario 48: long-running transaction blocks vacuum and replication cleanup (Troubleshooting, 2 h)\n- TSH-049 Scenario 49: extension or library fails to load after a package update (Troubleshooting, 2 h)\n- TSH-050 Scenario 50: time zone or encoding problem in application data (Troubleshooting, 2 h)\n- TSH-051 Scenario 51: multi-fault production incident (Troubleshooting, 4 h)\n- ASM-019 Troubleshooting assessment (Assessment, 4 h)\n\n## Phase 20 - Enterprise Capstone\n\n### MOD-63 Final Enterprise Lab\n\nTopics: Applications to HAProxy to PgBouncer to primary and read replica; WAL; Backups; PITR; Monitoring stack with Prometheus, Grafana and Loki; Security with Wazuh and OpenBao; Ansible\n\n- LAB-087 Enterprise PostgreSQL Cluster (Lab, 10 h)\n- LAB-088 Operations drill on the enterprise cluster (Lab, 6 h)\n\n### MOD-64 Capstone: Enterprise PostgreSQL Database Platform\n\nTopics: Primary and read replica; Patroni; etcd; HAProxy; PgBouncer; Backup; PITR; WAL archiving; Monitoring; Logging; Security; OpenBao; Ansible; Automated health checks; Disaster recovery; Application workload; Multiple users; Role-based access; RLS; Auditing; Performance monitoring; Replication; Automated backup; Failover\n\n- CAP-001 Business and database requirements (Capstone, 4 h)\n- CAP-002 Logical and physical architecture (Capstone, 5 h)\n- CAP-003 ER diagram, schema design, SQL scripts and indexing strategy (Capstone, 8 h)\n- CAP-004 Security design: roles, RLS, TLS, auditing and secrets (Capstone, 6 h)\n- CAP-005 Backup strategy, DR strategy and WAL archiving (Capstone, 6 h)\n- CAP-006 Replication and HA design and build (Capstone, 8 h)\n- CAP-007 Monitoring architecture, logging and dashboards (Capstone, 6 h)\n- CAP-008 Automation scripts, Ansible playbooks and health checks (Capstone, 8 h)\n- CAP-009 Performance report (Capstone, 5 h)\n- CAP-010 Runbooks and troubleshooting guide (Capstone, 5 h)\n- CAP-011 Disaster recovery test, failover test and security audit (Capstone, 6 h)\n- CAP-012 Final technical report, executive architecture document and presentation (Capstone, 6 h)\n- ASM-020 Final assessment (Assessment, 3 h)\n\n### MOD-65 Career Preparation\n\nTopics: PostgreSQL DBA, Senior PostgreSQL DBA, PostgreSQL Developer, Database Engineer, Database Reliability Engineer, Database Performance Engineer, Database Architect and Cloud Database Engineer interviews\n\n- ASG-014 Portfolio: publish the ten projects (Assignment, 4 h)\n- ASG-015 Interview bank: SQL and PostgreSQL internals (Assignment, 4 h)\n- ASG-016 Interview bank: performance, replication, HA and backup scenarios (Assignment, 4 h)\n- ASG-017 Interview bank: security, troubleshooting and architecture (Assignment, 4 h)\n- ASM-021 Mock interview and live troubleshooting (Assessment, 3 h)\n",
   "parent": "Wiki"
  }
 ]
}
