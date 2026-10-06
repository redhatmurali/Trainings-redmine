# Enterprise Network Engineering with MikroTik - one-shot Redmine installer
#
# Put this file and mikrotik_issues.csv in the same folder. Run on the Redmine server,
# from the Redmine root directory, as the Redmine OS user:
#
#   STUDENTS=alice,bob INSTRUCTORS=admin \
#     bundle exec rails runner -e production /path/to/install_mikrotik_project.rb
#
# Environment variables (all optional):
#   CSV            path to mikrotik_issues.csv (default: same folder as this script)
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
csv_path   = File.join(course_dir, 'mikrotik_issues.csv') if csv_path.empty?
halt("not found: #{csv_path} (set CSV=/path/to/mikrotik_issues.csv)") unless File.file?(csv_path)

# The project definition (fields, queries, wiki pages) is embedded at the end of this file.
embedded = File.read(File.expand_path(__FILE__), :encoding => 'utf-8').split("\n__END__\n", 2)[1]
halt('embedded project definition missing from this script') if embedded.to_s.strip.empty?
course = JSON.parse(embedded)
$tag   = course['tag'].to_s.empty? ? 'course' : course['tag']
rows   = CSV.read(csv_path, :headers => true, :encoding => 'bom|utf-8').map(&:to_h)
halt('mikrotik_issues.csv is empty') if rows.empty?
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
 "tag": "mikrotik",
 "project": {
  "name": "Enterprise Network Engineering with MikroTik",
  "identifier": "enterprise-network-engineering-mikrotik",
  "description": "Job-oriented Enterprise Network Engineering programme with MikroTik RouterOS as the hands-on platform. Every topic follows Concept -> Design -> MikroTik Configuration -> Lab -> Troubleshooting -> Security -> Automation, across 20 phases ending in an enterprise multi-site capstone. One shared project; every student has a personal copy of each issue."
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
  "Design"
 ],
 "versions": [
  "V01.0 Networking Fundamentals",
  "V02.0 Ethernet & Switching",
  "V03.0 IP Addressing & Subnetting",
  "V04.0 MikroTik RouterOS",
  "V05.0 VLAN & Switching",
  "V06.0 Routing",
  "V07.0 OSPF",
  "V08.0 BGP",
  "V09.0 Firewall & NAT",
  "V10.0 VPN",
  "V11.0 Wireless",
  "V12.0 QoS",
  "V13.0 High Availability",
  "V14.0 Network Security",
  "V15.0 Monitoring",
  "V16.0 Automation",
  "V17.0 Enterprise Architecture",
  "V18.0 Cloud Networking",
  "V19.0 Advanced Networking",
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
   "name": "Protocol",
   "format": "list",
   "multiple": true,
   "trackers": "all",
   "csv": "Protocol",
   "sort": true
  },
  {
   "name": "RouterOS Version",
   "format": "string",
   "trackers": "all",
   "csv": "RouterOS Version"
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
      "tracker:Lab+Configuration"
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
   "name": "Dashboard: networking skills",
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
   "name": "Dashboard: MikroTik skills",
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
     "cf:Tool",
     "=",
     [
      "MikroTik RouterOS"
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
   "name": "Dashboard: automation projects",
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
    ],
    [
     "category_id",
     "=",
     [
      "category:Automation"
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
   "text": "# Enterprise Network Engineering with MikroTik\n\nJob-oriented Enterprise Network Engineering programme with MikroTik RouterOS as the hands-on platform. Every topic follows Concept -> Design -> MikroTik Configuration -> Lab -> Troubleshooting -> Security -> Automation, across 20 phases ending in an enterprise multi-site capstone. One shared project; every student has a personal copy of each issue.\n\n## How to work an issue\n\n1. Open your next issue from the saved query *My next tasks*.\n2. Set the status to **In Progress** and do the steps. Log time at the end of every session.\n3. Set **Testing**, check every acceptance criterion, attach the evidence.\n4. Set **Review**. The instructor sets **Completed** or **Reopened**.\n\n## Pages\n\n- [[Lab_Environment]]\n- [[Lab_Topologies]]\n- [[VLAN_Plan]]\n- [[Workflow_and_Statuses]]\n- [[Assessment_and_Grading]]\n- [[Evidence_Standards]]\n- [[Troubleshooting_Report]]\n- [[Dashboard_Guide]]\n- [[Skill_Matrix]]\n- [[Tool_Matrix]]\n- [[Module_Index]]"
  },
  {
   "title": "Lab_Environment",
   "text": "# Lab environment\n\nPlatforms: GNS3 or EVE-NG for multi-router topologies; Proxmox, VMware or VirtualBox for the supporting virtual machines. MikroTik CHR is the default router; use a physical MikroTik device where available.\n\n| System | Minimum size | Purpose |\n|---|---|---|\n| MikroTik CHR (x2 to x12) | 1 vCPU / 256 MB / 1 GB each | Routers and switches for every topology; free licence is limited to 1 Mbit/s per interface, a 60-day trial removes the limit |\n| Physical MikroTik router or access point | Any current RouterOS 7 device | Wireless labs, switch-chip hardware offloading, real cabling |\n| Ubuntu Server | 2 vCPU / 4 GB / 40 GB | Services, syslog, iperf3, test server |\n| Windows Server | 2 vCPU / 4 GB / 60 GB | Directory, DNS and DHCP comparisons, RADIUS for wireless |\n| Windows client | 2 vCPU / 4 GB / 60 GB | User workstation, VPN client |\n| Linux test client | 1 vCPU / 2 GB / 20 GB | Measurements and instructor-approved test events inside the lab |\n| Monitoring host | 4 vCPU / 8 GB / 100 GB | Zabbix or LibreNMS, Prometheus, Grafana, Loki, ntopng, The Dude |\n| Security monitoring host | 4 vCPU / 8 GB / 100 GB | Wazuh, Suricata, Zeek, TheHive (phase 14) |\n| Automation host | 2 vCPU / 4 GB / 40 GB | Ansible, Python, Git |\n\nAll scans, load tests and test events are run only inside the lab against lab systems.",
   "parent": "Wiki"
  },
  {
   "title": "Lab_Topologies",
   "text": "# Lab topologies\n\n## LAB 1 - Single router\n```\nInternet\n   |\nMikroTik\n   |\n  LAN\n```\n## LAB 2 - Switched LAN\n```\nMikroTik\n   |\n Switch\n /  |  \\\nPC  PC  Server\n```\n## LAB 3 - VLANs\n```\n        MikroTik\n        /      \\\n    VLAN10    VLAN20\n    Users     Servers\n```\n## LAB 4 - Dual ISP\n```\nISP1 --+\n       +-- MikroTik -- LAN\nISP2 --+\n```\n## LAB 5 - Site-to-site\n```\nHQ -- VPN -- Branch\n```\n## LAB 6 - Enterprise\n```\nISP\n |\nEdge Router\n |\nCore\n +-- Distribution\n +-- Servers\n +-- Users\n +-- WiFi\n +-- Security\n```\n## FINAL - Enterprise multi-site\n```\n            INTERNET\n           /        \\\n        ISP-1      ISP-2\n           \\        /\n          Edge (MikroTik x2, VRRP, BGP)\n                |\n             Firewall\n                |\n            Core (OSPF)\n          /     |      \\\n      Servers  Users   WiFi      -- VPN --  Branches 1-4, Cloud\n          |\n     Security zone -> Monitoring / SIEM -> Grafana / Zabbix\n```",
   "parent": "Wiki"
  },
  {
   "title": "VLAN_Plan",
   "text": "# Course VLAN plan\n\n| VLAN | Name | Use |\n|---|---|---|\n| 10 | Management | Device management, monitoring, automation |\n| 20 | Servers | Internal services |\n| 30 | Users | Workstations |\n| 40 | Voice | IP phones |\n| 50 | Guest | Internet only |\n| 60 | IoT | Printers, cameras, sensors |\n| 70 | Security | Sensors, SIEM, logging |",
   "parent": "Wiki"
  },
  {
   "title": "Workflow_and_Statuses",
   "text": "# Workflow and statuses\n\n| Status | Meaning |\n|---|---|\n| New | Template or unassigned |\n| Assigned | Belongs to a student, not started |\n| In Progress | Being worked on |\n| Blocked | Cannot continue; a note states the blocker |\n| Testing | Steps done; student checks the acceptance criteria and collects evidence |\n| Review | Submitted to the instructor |\n| Completed | Approved by the instructor |\n| Reopened | Changes requested |\n| Rejected | Waived or not applicable (instructor only) |\n\nPrerequisites are *blocked by* relations: an issue cannot be closed while its blocker is open.",
   "parent": "Wiki"
  },
  {
   "title": "Assessment_and_Grading",
   "text": "# Assessment and grading\n\n| Element | Where | Scoring |\n|---|---|---|\n| Theory | Theory issues, MCQ and short-answer assessments | MCQ, short answer, design questions, protocol analysis |\n| Practical | Configuration, Lab and Troubleshooting issues, practical exams | Router configuration, VLAN, routing, firewall, VPN, troubleshooting, monitoring, automation |\n| Design | Assignments and design reviews | Enterprise, branch, ISP and data center architecture |\n| Projects | 7 enterprise projects and 8 automation projects | 0-100 on result, tests, documentation, repository |\n| Capstone | CAP issues and the final assessment | 0-100 against the capstone rubric |\n\nPass mark 70. Programme grade: phase assessments 30 %, projects 30 %, capstone 40 %. A student is not complete on theory alone: every phase gate requires its labs and troubleshooting cases, and the programme requires the projects and the capstone.",
   "parent": "Wiki"
  },
  {
   "title": "Evidence_Standards",
   "text": "# Evidence standards\n\n| Evidence | Minimum content |\n|---|---|\n| Notes | Own words, one page, diagrams where useful |\n| Configuration export | RouterOS export with sensitive values hidden, committed to the repository |\n| Screenshot + command output | Shows device identity and the result; text output pasted as text |\n| Root cause report | Problem, root cause, evidence, fix, validation, prevention |\n| Written deliverable | Document attached or linked |\n| Repository link | Commit link with README, code or playbook, and a run log |\n| Repository link + documentation | Repository plus design, configuration, test results |\n| Scored result | Score and feedback recorded by the instructor |",
   "parent": "Wiki"
  },
  {
   "title": "Troubleshooting_Report",
   "text": "# Troubleshooting report\n\nEvery troubleshooting issue is closed with these six sections:\n\n1. **Problem** - what was observed and by whom\n2. **Root cause** - the single underlying cause\n3. **Evidence** - outputs, captures or logs that prove it\n4. **Fix** - the change made\n5. **Validation** - tests showing it works\n6. **Prevention** - what stops it happening again\n\nMethod: Problem -> Layer 1 -> Layer 2 -> Layer 3 -> Layer 4 -> Layer 7 -> Application. Change one thing at a time.",
   "parent": "Wiki"
  },
  {
   "title": "Dashboard_Guide",
   "text": "# Dashboard guide\n\nThe dashboard is the set of saved queries in the issue list sidebar. Add them to *My page* as custom query blocks.\n\n| Section | Saved query |\n|---|---|\n| Course progress | Dashboard: overall completion; phase completion; module completion; labs completed; assessment completion |\n| Networking skills | Dashboard: networking skills (grouped by category: Routing, Switching, VLAN, Firewall, VPN, Wireless, QoS, High Availability, Security, Automation, ...) |\n| MikroTik skills | Dashboard: MikroTik skills (issues using RouterOS, grouped by category) |\n| Projects | Dashboard: projects completed; troubleshooting cases; automation projects; capstone status |\n\nFor % done to follow the status, set *Administration > Settings > Issue tracking > Calculate the issue done ratio* to *Use the issue status* (global setting).",
   "parent": "Wiki"
  },
  {
   "title": "Skill_Matrix",
   "text": "# Skill matrix\n\n| Network technology | Level | Modules | Tasks | Hours |\n|---|---|---|---|---|\n| Fundamentals | Level 1 - Networking Foundation | MOD-01, MOD-02, MOD-03 | 14 | 41 |\n| Switching | Level 1 - Networking Foundation | MOD-04 | 6 | 16 |\n| IP Addressing | Level 1 - Networking Foundation | MOD-05, MOD-06 | 8 | 26 |\n| RouterOS | Level 2 - MikroTik Network Engineering | MOD-07, MOD-08, MOD-09, MOD-10, MOD-11 | 19 | 53 |\n| Switching | Level 2 - MikroTik Network Engineering | MOD-12 | 4 | 11 |\n| VLAN | Level 2 - MikroTik Network Engineering | MOD-13 | 8 | 25 |\n| Routing | Level 2 - MikroTik Network Engineering | MOD-14 | 9 | 28 |\n| OSPF | Level 3 - Enterprise Network Engineering | MOD-15 | 10 | 34 |\n| BGP | Level 3 - Enterprise Network Engineering | MOD-16, MOD-45 | 12 | 54 |\n| Firewall | Level 2 - MikroTik Network Engineering | MOD-17, MOD-19 | 12 | 40 |\n| NAT | Level 2 - MikroTik Network Engineering | MOD-18 | 4 | 12 |\n| VPN | Level 2 - MikroTik Network Engineering | MOD-20, MOD-21 | 9 | 31 |\n| VPN | Level 3 - Enterprise Network Engineering | MOD-22 | 6 | 19 |\n| Wireless | Level 2 - MikroTik Network Engineering | MOD-23 | 8 | 25 |\n| QoS | Level 2 - MikroTik Network Engineering | MOD-24 | 8 | 26 |\n| High Availability | Level 3 - Enterprise Network Engineering | MOD-25, MOD-26 | 11 | 45 |\n| Security | Level 2 - MikroTik Network Engineering | MOD-27 | 4 | 12 |\n| Security | Level 3 - Enterprise Network Engineering | MOD-28, MOD-29 | 7 | 28 |\n| Monitoring | Level 3 - Enterprise Network Engineering | MOD-30, MOD-31, MOD-32 | 13 | 48 |\n| Automation | Level 3 - Enterprise Network Engineering | MOD-33, MOD-34, MOD-35 | 19 | 82 |\n| Architecture | Level 3 - Enterprise Network Engineering | MOD-36, MOD-37, MOD-38, MOD-39, MOD-47 | 22 | 140 |\n| Cloud | Level 3 - Enterprise Network Engineering | MOD-40, MOD-41 | 8 | 32 |\n| IPv6 | Level 3 - Enterprise Network Engineering | MOD-42 | 5 | 17 |\n| Routing | Level 3 - Enterprise Network Engineering | MOD-43, MOD-44 | 6 | 22 |\n| Troubleshooting | Level 3 - Enterprise Network Engineering | MOD-46 | 10 | 30 |\n| Career | Level 3 - Enterprise Network Engineering | MOD-48 | 5 | 19 |",
   "parent": "Wiki"
  },
  {
   "title": "Tool_Matrix",
   "text": "# Tool matrix\n\n| Tool | Modules | Hours in those modules |\n|---|---|---|\n| Ansible | MOD-34, MOD-35, MOD-38, MOD-47 | 163 |\n| AWS | MOD-40 | 12 |\n| Azure | MOD-41 | 20 |\n| community.routeros | MOD-34 | 18 |\n| curl | MOD-03 | 21 |\n| dig | MOD-03, MOD-10 | 29 |\n| draw.io | MOD-36, MOD-37 | 26 |\n| EVE-NG | MOD-01 | 12 |\n| Git | MOD-11, MOD-33, MOD-34, MOD-35, MOD-47, MOD-48 | 206 |\n| GNS3 | MOD-01 | 12 |\n| Grafana | MOD-29, MOD-30, MOD-31, MOD-32, MOD-47 | 150 |\n| iperf3 | MOD-24, MOD-32, MOD-46 | 76 |\n| LibreNMS | MOD-30 | 18 |\n| Loki | MOD-31 | 10 |\n| MikroTik CHR | MOD-01 | 12 |\n| MikroTik REST API | MOD-33 | 17 |\n| MikroTik RouterOS | MOD-07, MOD-08, MOD-09, MOD-10, MOD-11, MOD-12, MOD-13, MOD-14, MOD-15, MOD-16, MOD-17, MOD-18, MOD-19, MOD-20, MOD-21, MOD-22, MOD-23, MOD-24, MOD-25, MOD-26, MOD-27, MOD-28, MOD-29, MOD-30, MOD-31, MOD-32, MOD-34, MOD-37, MOD-38, MOD-39, MOD-40, MOD-41, MOD-42, MOD-43, MOD-44, MOD-45, MOD-46, MOD-47 | 742 |\n| mtr | MOD-14, MOD-25, MOD-46 | 85 |\n| Netcat | MOD-03 | 21 |\n| Nmap | MOD-03, MOD-17, MOD-27, MOD-46 | 88 |\n| nslookup | MOD-03, MOD-10 | 29 |\n| ntopng | MOD-30 | 18 |\n| OpenSearch | MOD-31 | 10 |\n| ping | MOD-02, MOD-03, MOD-46 | 59 |\n| Prometheus | MOD-29, MOD-30 | 35 |\n| Proxmox | MOD-01 | 12 |\n| Python | MOD-33, MOD-35 | 64 |\n| RouterOS API | MOD-33, MOD-35 | 64 |\n| SSH | MOD-07, MOD-11, MOD-27, MOD-33 | 56 |\n| Suricata | MOD-29 | 17 |\n| tcpdump | MOD-03, MOD-46 | 51 |\n| The Dude | MOD-30 | 18 |\n| TheHive | MOD-29 | 17 |\n| traceroute | MOD-02, MOD-03, MOD-14, MOD-25, MOD-46 | 114 |\n| VirtualBox | MOD-01 | 12 |\n| Wazuh | MOD-29, MOD-31, MOD-47 | 112 |\n| WebFig | MOD-07 | 7 |\n| WinBox | MOD-01, MOD-07, MOD-08, MOD-11, MOD-12, MOD-13, MOD-17, MOD-19, MOD-23, MOD-27 | 160 |\n| Wireshark | MOD-02, MOD-03, MOD-04, MOD-09, MOD-12, MOD-13, MOD-15, MOD-16, MOD-17, MOD-18, MOD-20, MOD-21, MOD-42, MOD-46 | 279 |\n| Zabbix | MOD-30, MOD-47 | 103 |\n| Zeek | MOD-29 | 17 |",
   "parent": "Wiki"
  },
  {
   "title": "Module_Index",
   "text": "# Module index\n\n## Phase 01 - Networking Fundamentals\n\n### MOD-01 Lab Environment\n\nTopics: Lab platforms: GNS3, EVE-NG, Proxmox, VMware, VirtualBox; MikroTik CHR; Physical MikroTik router where available; Supporting systems: Ubuntu, Windows Server, Windows client, monitoring and automation hosts\n\n- THY-001 Lab platform options and the course topologies (Theory, 2 h)\n- LAB-001 Install the lab platform and import MikroTik CHR (Lab, 4 h)\n- LAB-002 Build supporting hosts: Ubuntu, Windows and a test client (Lab, 4 h)\n- DOC-001 Lab inventory and topology diagram (Documentation, 2 h)\n\n### MOD-02 OSI Model and Layered Troubleshooting\n\nTopics: Layer 1; Layer 2; Layer 3; Layer 4; Layer 5; Layer 6; Layer 7; Encapsulation; PDU names; Troubleshooting by OSI layer\n\n- THY-002 The seven layers, encapsulation and PDUs (Theory, 3 h)\n- LAB-003 See the layers in a packet capture (Lab, 3 h)\n- ASG-001 Troubleshooting by layer: method sheet (Assignment, 2 h)\n\n### MOD-03 TCP/IP Protocols\n\nTopics: IPv4; IPv6; TCP; UDP; ICMP; ARP; DHCP; DNS; HTTP; HTTPS; SSH; FTP; SMTP; SNMP; NTP; LDAP; SMB; RDP; Ports and sockets\n\n- THY-003 IP, ICMP and ARP (Theory, 3 h)\n- THY-004 TCP and UDP (Theory, 3 h)\n- LAB-004 Capture ARP, ICMP, TCP and UDP (Lab, 4 h)\n- LAB-005 Application protocols with command-line tools (Lab, 4 h)\n- LAB-006 Discover lab hosts and services with Nmap (Lab, 3 h)\n- TSH-001 Scenario 01: host cannot reach the gateway (Troubleshooting, 2 h)\n- ASM-001 Phase 01 assessment: fundamentals (Assessment, 2 h)\n\n## Phase 02 - Ethernet & Switching\n\n### MOD-04 Ethernet and Switching Concepts\n\nTopics: Ethernet; MAC addresses; CAM tables; Broadcast domains; Collision domains; Switching; VLAN; Access ports; Trunk ports; Native VLAN; Voice VLAN; Private VLAN concepts; STP; RSTP; MSTP; LACP; Link aggregation\n\n- THY-005 Ethernet frames, MAC addresses and CAM tables (Theory, 3 h)\n- THY-006 VLANs, access and trunk ports, native and voice VLAN (Theory, 3 h)\n- THY-007 Spanning Tree: STP, RSTP and MSTP (Theory, 3 h)\n- THY-008 Link aggregation and LACP (Theory, 2 h)\n- LAB-007 Observe MAC learning and a broadcast domain (Lab, 3 h)\n- ASM-002 Phase 02 assessment: switching concepts (Assessment, 2 h)\n\n## Phase 03 - IP Addressing & Subnetting\n\n### MOD-05 IPv4 Addressing and Subnetting\n\nTopics: IPv4; Public IP; Private IP; Loopback; APIPA; CIDR; Subnetting; Supernetting; VLSM; Route summarization\n\n- THY-009 IPv4 address types and CIDR (Theory, 3 h)\n- LAB-008 IPv4 Subnetting (Lab, 4 h)\n- LAB-009 VLSM addressing plan (Lab, 4 h)\n- LAB-010 Supernetting and route summarization (Lab, 3 h)\n- ASG-002 Enterprise IP addressing plan for the course network (Assignment, 4 h)\n\n### MOD-06 IPv6 Addressing\n\nTopics: IPv6 addressing; Global unicast; Link-local; Multicast; Prefixes; SLAAC; NDP\n\n- THY-010 IPv6 address types and notation (Theory, 3 h)\n- LAB-011 IPv6 subnetting plan (Lab, 3 h)\n- ASM-003 Phase 03 assessment: subnetting practical (Assessment, 2 h)\n\n## Phase 04 - MikroTik RouterOS\n\n### MOD-07 RouterOS Architecture and Management\n\nTopics: RouterOS architecture; WinBox; WebFig; CLI; Configuration management; Packages; Licence levels; Safe Mode\n\n- THY-011 RouterOS architecture, packages and licence levels (Theory, 2 h)\n- CFG-001 First access with WinBox, WebFig and CLI (Configuration, 3 h)\n- CFG-002 Identity, clock, NTP and system resources (Configuration, 2 h)\n\n### MOD-08 Interfaces and IP Addressing\n\nTopics: Interfaces; Interface lists; IP addressing; ARP; Neighbor discovery; Loopback\n\n- CFG-003 Interfaces, comments and interface lists (Configuration, 2 h)\n- LAB-012 Build a MikroTik LAN (Lab, 4 h)\n- TSH-002 Scenario 02: wrong gateway on the LAN (Troubleshooting, 2 h)\n\n### MOD-09 DHCP\n\nTopics: DHCP server; DHCP client; DHCP relay; DHCP reservations; DHCP options; Multiple DHCP scopes; DHCP security; Troubleshooting\n\n- THY-012 DHCP operation: discover, offer, request, acknowledge (Theory, 2 h)\n- LAB-013 Configure DHCP (Lab, 3 h)\n- LAB-014 Multiple scopes and DHCP relay (Lab, 3 h)\n- TSH-003 Scenario 03: DHCP failure (Troubleshooting, 2 h)\n\n### MOD-10 DNS\n\nTopics: DNS architecture; Recursive DNS; Authoritative DNS; Forwarders; Caching; Split DNS; DNS security; DNS troubleshooting; MikroTik DNS cache; Static DNS; DoH concepts; DNS forwarding\n\n- THY-013 DNS architecture: recursive, authoritative, forwarders, caching (Theory, 3 h)\n- LAB-015 Configure DNS (Lab, 3 h)\n- TSH-004 Scenario 04: DNS failure (Troubleshooting, 2 h)\n\n### MOD-11 Users, Backup and Upgrade\n\nTopics: User management; Groups; Backup; Export; Upgrade; Logging; Configuration management\n\n- CFG-004 Users, groups and SSH keys (Configuration, 2 h)\n- CFG-005 Backup, export and restore (Configuration, 3 h)\n- CFG-006 Upgrade RouterOS and firmware (Configuration, 2 h)\n- CFG-007 Logging topics and remote syslog (Configuration, 2 h)\n- PROJECT-001 Small Business Network (Project, 8 h)\n- ASM-004 Phase 04 assessment: router configuration practical (Assessment, 3 h)\n\n## Phase 05 - VLAN & Switching\n\n### MOD-12 MikroTik Bridging\n\nTopics: Bridge; Bridge ports; Bridge VLAN filtering; Hardware offloading; VLAN-aware bridge; Access ports; Trunk ports; Hybrid ports; Bridge firewall; STP; RSTP; MSTP\n\n- THY-014 The RouterOS bridge and hardware offloading (Theory, 3 h)\n- CFG-008 Create a bridge and add ports (Configuration, 2 h)\n- LAB-016 Spanning Tree on MikroTik (Lab, 4 h)\n- TSH-005 Scenario 05: layer 2 loop (Troubleshooting, 2 h)\n\n### MOD-13 VLAN and Inter-VLAN Routing\n\nTopics: VLAN design; VLAN trunking; Inter-VLAN routing; Router-on-a-stick; Layer 3 switching; MikroTik VLAN filtering; VLAN security; VLAN isolation; Management, Servers, Users, Voice, Guest, IoT and Security VLANs\n\n- THY-015 VLAN design for an enterprise (Theory, 3 h)\n- LAB-017 Configure VLANs (Lab, 5 h)\n- LAB-018 Inter-VLAN Routing (Lab, 4 h)\n- LAB-019 VLAN isolation with the firewall (Lab, 3 h)\n- LAB-020 Bonding and LACP (Lab, 3 h)\n- TSH-006 Scenario 06: wrong VLAN on an access port (Troubleshooting, 2 h)\n- TSH-007 Scenario 07: trunk not carrying a VLAN (Troubleshooting, 2 h)\n- ASM-005 Phase 05 assessment: VLAN implementation practical (Assessment, 3 h)\n\n## Phase 06 - Routing\n\n### MOD-14 Static and Policy Routing\n\nTopics: Static routes; Default routes; Connected routes; Recursive routing; Policy routing; Route tables; Route filtering; Route redistribution concepts; Administrative distance; ECMP; Failover\n\n- THY-016 The routing table and route selection (Theory, 3 h)\n- LAB-021 Static Routing (Lab, 4 h)\n- LAB-022 Floating static routes and check-gateway failover (Lab, 3 h)\n- LAB-023 Recursive routing (Lab, 3 h)\n- LAB-024 Policy routing with route tables and rules (Lab, 4 h)\n- LAB-025 ECMP (Lab, 3 h)\n- TSH-008 Scenario 08: incorrect route (Troubleshooting, 2 h)\n- TSH-009 Scenario 09: asymmetric routing (Troubleshooting, 3 h)\n- ASM-006 Phase 06 assessment: routing practical (Assessment, 3 h)\n\n## Phase 07 - OSPF\n\n### MOD-15 OSPF\n\nTopics: OSPF fundamentals; Areas; Area 0; Neighbors; LSAs; LSDB; DR/BDR; Cost; Passive interfaces; Authentication; Route filtering; Redistribution; OSPF troubleshooting\n\n- THY-017 OSPF fundamentals: neighbors, LSDB and SPF (Theory, 4 h)\n- THY-018 Areas, LSA types and route types (Theory, 3 h)\n- LAB-026 OSPF (Lab, 4 h)\n- LAB-027 Multi-Area OSPF (Lab, 5 h)\n- LAB-028 Redundant OSPF and failover (Lab, 4 h)\n- LAB-029 OSPF authentication (Lab, 2 h)\n- LAB-030 OSPF redistribution and route filtering (Lab, 4 h)\n- TSH-010 Scenario 10: OSPF adjacency failure (Troubleshooting, 3 h)\n- TSH-011 Scenario 11: OSPF route missing (Troubleshooting, 2 h)\n- ASM-007 Phase 07 assessment: OSPF practical (Assessment, 3 h)\n\n## Phase 08 - BGP\n\n### MOD-16 BGP\n\nTopics: BGP fundamentals; eBGP; iBGP; AS; ASN; Route advertisements; Route selection; Local preference; MED; AS Path; Communities; Prefix filtering; Route filtering; Default routes; Transit; Peering; Internet edge architecture\n\n- THY-019 BGP fundamentals: AS, sessions and path attributes (Theory, 4 h)\n- THY-020 Route selection, transit, peering and internet edge design (Theory, 3 h)\n- LAB-031 BGP (Lab, 4 h)\n- LAB-032 iBGP with OSPF underlay (Lab, 4 h)\n- LAB-033 BGP filtering and route policies (Lab, 5 h)\n- LAB-034 Dual ISP with BGP and failover (Lab, 5 h)\n- LAB-035 ISP simulation (Lab, 5 h)\n- TSH-012 Scenario 12: BGP session will not establish (Troubleshooting, 3 h)\n- TSH-013 Scenario 13: BGP prefix not advertised or not received (Troubleshooting, 3 h)\n- ASM-008 Phase 08 assessment: BGP practical (Assessment, 3 h)\n\n## Phase 09 - Firewall & NAT\n\n### MOD-17 MikroTik Firewall\n\nTopics: Firewall architecture; Input chain; Forward chain; Output chain; Connection tracking; Stateful firewall; Address lists; Interface lists; Service restrictions; Port restrictions; Logging; Rate limiting; SYN protection; Brute-force protection; Bogon filtering; Spoofing protection\n\n- THY-021 Packet flow, chains and connection tracking (Theory, 4 h)\n- LAB-036 Firewall (Lab, 5 h)\n- LAB-037 Address lists, service and port restrictions (Lab, 3 h)\n- LAB-038 Logging, rate limiting and connection limits (Lab, 3 h)\n- LAB-039 Bogon, spoofing and management brute-force protection (Lab, 3 h)\n- ASG-003 Enterprise firewall policy (Assignment, 4 h)\n- TSH-014 Scenario 14: firewall blocking legitimate traffic (Troubleshooting, 3 h)\n\n### MOD-18 NAT\n\nTopics: Static NAT; Dynamic NAT; PAT; Source NAT; Destination NAT; Port forwarding; Hairpin NAT; 1:1 NAT; NAT troubleshooting; src-nat; masquerade; dst-nat; netmap; NAT logging\n\n- THY-022 NAT types and where NAT happens in the packet flow (Theory, 3 h)\n- LAB-040 NAT (Lab, 4 h)\n- LAB-041 Hairpin NAT and 1:1 NAT (Lab, 3 h)\n- TSH-015 Scenario 15: port forward not working (Troubleshooting, 2 h)\n\n### MOD-19 Mangle\n\nTopics: Packet marking; Connection marking; Routing marks; Policy routing; QoS marking; Multi-WAN; Traffic classification\n\n- THY-023 Mangle chains and marks (Theory, 3 h)\n- LAB-042 Connection and packet marking for traffic classification (Lab, 4 h)\n- LAB-043 Routing marks for policy routing (Lab, 3 h)\n- LAB-044 Clamp TCP MSS (Lab, 2 h)\n- ASM-009 Phase 09 assessment: firewall and NAT practical (Assessment, 3 h)\n\n## Phase 10 - VPN\n\n### MOD-20 WireGuard\n\nTopics: WireGuard site-to-site; Remote access; Routing; Key management; Firewall integration\n\n- THY-024 VPN concepts and WireGuard design (Theory, 3 h)\n- LAB-045 WireGuard VPN (Lab, 4 h)\n- LAB-046 WireGuard remote access (Lab, 3 h)\n- LAB-047 OSPF over WireGuard (Lab, 3 h)\n\n### MOD-21 IPsec\n\nTopics: IKE; Phase 1; Phase 2; PSK; Certificates; Site-to-site VPN\n\n- THY-025 IKEv2, phase 1 and phase 2 (Theory, 3 h)\n- LAB-048 IPsec VPN (Lab, 5 h)\n- LAB-049 IPsec with certificates (Lab, 4 h)\n- TSH-016 Scenario 16: VPN will not establish (Troubleshooting, 3 h)\n- TSH-017 Scenario 17: VPN up but no traffic (Troubleshooting, 3 h)\n\n### MOD-22 Other VPN Technologies and VPN Designs\n\nTopics: GRE; EoIP; L2TP/IPsec; SSTP; OpenVPN concepts; Branch-to-HQ VPN; Remote worker VPN; Site-to-site VPN; Redundant VPN; VPN failover\n\n- THY-026 GRE, EoIP, L2TP/IPsec, SSTP and OpenVPN compared (Theory, 2 h)\n- LAB-050 GRE over IPsec with OSPF (Lab, 4 h)\n- LAB-051 EoIP layer 2 extension (Lab, 2 h)\n- LAB-052 L2TP/IPsec remote worker VPN (Lab, 3 h)\n- LAB-053 Redundant VPN and VPN failover (Lab, 5 h)\n- ASM-010 Phase 10 assessment: VPN practical (Assessment, 3 h)\n\n## Phase 11 - Wireless\n\n### MOD-23 Wireless Networking\n\nTopics: Wi-Fi fundamentals; 2.4 GHz; 5 GHz; 6 GHz concepts; Channels; Channel width; Interference; Roaming; SSID; WPA2; WPA3; Enterprise Wi-Fi; Guest Wi-Fi; Captive portal; Wireless security; CAPsMAN; Access points; Wireless profiles; VLAN integration\n\n- THY-027 Wi-Fi fundamentals: bands, channels, width and interference (Theory, 3 h)\n- THY-028 Wireless security: WPA2, WPA3, enterprise authentication, guest access (Theory, 3 h)\n- LAB-054 Configure an access point with SSID and security profile (Lab, 4 h)\n- LAB-055 Multiple SSIDs mapped to VLANs (Lab, 3 h)\n- LAB-056 Central management with CAPsMAN (Lab, 5 h)\n- LAB-057 Guest Wi-Fi with captive portal (Lab, 3 h)\n- TSH-018 Scenario 18: wireless clients connect but have no network (Troubleshooting, 2 h)\n- ASM-011 Phase 11 assessment: wireless (Assessment, 2 h)\n\n## Phase 12 - QoS\n\n### MOD-24 Quality of Service\n\nTopics: QoS; Bandwidth management; Traffic shaping; Queuing; Priority; Latency; Jitter; Packet loss; VoIP QoS; DSCP; Traffic classification; Simple Queues; Queue Trees; PCQ; Mangle-based QoS\n\n- THY-029 QoS concepts: latency, jitter, loss, shaping and priority (Theory, 3 h)\n- LAB-058 QoS (Lab, 4 h)\n- LAB-059 Queue trees with mangle marks (Lab, 5 h)\n- LAB-060 PCQ for fair sharing (Lab, 3 h)\n- LAB-061 VoIP prioritization (Lab, 3 h)\n- LAB-062 Video, business application priority and guest limiting (Lab, 3 h)\n- TSH-019 Scenario 19: QoS misconfiguration (Troubleshooting, 3 h)\n- ASM-012 Phase 12 assessment: QoS practical (Assessment, 2 h)\n\n## Phase 13 - High Availability\n\n### MOD-25 Multi-WAN\n\nTopics: Dual ISP; Load balancing; Failover; ECMP; PCC; Policy routing; Recursive routing; Link monitoring; Automatic failover; Application-based routing; VPN-aware routing\n\n- THY-030 Multi-WAN design options (Theory, 3 h)\n- LAB-063 Dual ISP (Lab, 4 h)\n- LAB-064 PCC load balancing (Lab, 5 h)\n- LAB-065 Application-based and VPN-aware routing (Lab, 4 h)\n- TSH-020 Scenario 20: failover does not trigger (Troubleshooting, 3 h)\n- PROJECT-002 Dual-ISP Enterprise (Project, 8 h)\n\n### MOD-26 Gateway Redundancy and HA Design\n\nTopics: Redundancy; Single point of failure; HA design; VRRP; Gateway redundancy; Dual routers; Dual switches; Dual ISP; Link redundancy; LACP; Failover; Connection failover; Multi-router design\n\n- THY-031 HA design and single points of failure (Theory, 3 h)\n- LAB-066 VRRP (Lab, 4 h)\n- LAB-067 VRRP per VLAN with dual routers and dual uplinks (Lab, 5 h)\n- ASG-004 High-availability design review (Assignment, 3 h)\n- ASM-013 Phase 13 assessment: high availability practical (Assessment, 3 h)\n\n## Phase 14 - Network Security\n\n### MOD-27 MikroTik Hardening\n\nTopics: Secure WinBox; Secure SSH; Disable unused services; Management ACL; Trusted management networks; Strong authentication; User groups; Logging; Firewall; Address lists; MAC server restrictions; Neighbor discovery restrictions; Backup encryption; RouterOS update management\n\n- THY-032 RouterOS attack surface and hardening checklist (Theory, 2 h)\n- LAB-068 Harden management access (Lab, 4 h)\n- LAB-069 Users, groups, logging and encrypted backup (Lab, 3 h)\n- DOC-002 Golden hardening baseline (Documentation, 3 h)\n\n### MOD-28 Network Security Architecture\n\nTopics: Network segmentation; Zero Trust; Firewall architecture; IDS; IPS; DDoS protection; Port security; MAC security; DHCP snooping concepts; ARP protection; DNS security; Secure management; Management VLAN; Bastion host; VPN; MFA; SSH hardening\n\n- THY-033 Segmentation, Zero Trust and layered defence (Theory, 3 h)\n- LAB-070 Layer 2 protections: DHCP snooping, ARP and port security (Lab, 4 h)\n- LAB-071 Secure management: management VLAN, bastion and VPN (Lab, 4 h)\n\n### MOD-29 Network Security Integration\n\nTopics: Integration of MikroTik with Suricata, Zeek, Wazuh, Grafana, Prometheus and TheHive; Port mirroring; Security monitoring scenarios\n\n- LAB-072 Mirror traffic to Suricata and Zeek (Lab, 5 h)\n- LAB-073 Send MikroTik logs to Wazuh (Lab, 4 h)\n- LAB-074 Security monitoring scenarios (Lab, 5 h)\n- ASM-014 Phase 14 assessment: network security practical (Assessment, 3 h)\n\n## Phase 15 - Monitoring\n\n### MOD-30 Network Monitoring\n\nTopics: SNMP; Syslog; NetFlow concepts; Traffic monitoring; Interface monitoring; CPU; Memory; Temperature; Packet loss; Latency; Availability; Bandwidth\n\n- THY-034 Monitoring methods: SNMP, syslog, flow and active probes (Theory, 3 h)\n- LAB-075 Network Monitoring (Lab, 5 h)\n- LAB-076 Prometheus and Grafana dashboards (Lab, 5 h)\n- LAB-077 Traffic Flow export and ntopng (Lab, 3 h)\n- LAB-078 The Dude network map (Lab, 2 h)\n\n### MOD-31 Network Logging and Observability\n\nTopics: Firewall logs; VPN logs; DHCP logs; DNS logs; Routing logs; Authentication logs; Interface logs; System logs; Log pipeline: MikroTik to syslog to collector to Loki, OpenSearch or Wazuh to Grafana; Network health, security and infrastructure dashboards\n\n- LAB-079 Central log pipeline (Lab, 5 h)\n- LAB-080 Observability dashboards (Lab, 5 h)\n\n### MOD-32 Performance Engineering\n\nTopics: CPU utilization; Memory; Throughput; PPS; Latency; Jitter; Packet loss; MTU; MSS; Connection tracking; Hardware offloading; FastTrack; Queue performance\n\n- THY-035 What limits router performance (Theory, 3 h)\n- LAB-081 Performance benchmarking with iperf3, MikroTik and Grafana (Lab, 5 h)\n- TSH-021 Scenario 21: MTU issue (Troubleshooting, 3 h)\n- TSH-022 Scenario 22: high CPU (Troubleshooting, 3 h)\n- TSH-023 Scenario 23: packet loss (Troubleshooting, 3 h)\n- ASM-015 Phase 15 assessment: monitoring practical (Assessment, 3 h)\n\n## Phase 16 - Automation\n\n### MOD-33 Network Automation Foundations\n\nTopics: Python; REST APIs; SSH automation; Git; Infrastructure as Code concepts; Configuration templates; Configuration backup; Automated deployment; Automated validation\n\n- THY-036 Network automation and Infrastructure as Code concepts (Theory, 2 h)\n- LAB-082 Git workflow for network configuration (Lab, 3 h)\n- LAB-083 RouterOS scripting and scheduler (Lab, 4 h)\n- LAB-084 Python with the REST API: collect interface information (Lab, 4 h)\n- LAB-085 Python over SSH and the RouterOS API: push a change (Lab, 4 h)\n\n### MOD-34 Ansible and MikroTik\n\nTopics: Ansible architecture; Inventory; Variables; Templates; Playbooks; Roles; Handlers; Vault; Idempotency; Network automation; community.routeros; RouterOS modules; API; SSH; Configuration deployment\n\n- THY-037 Ansible architecture for network devices (Theory, 3 h)\n- LAB-086 Ansible Automation (Lab, 4 h)\n- LAB-087 Playbooks with the API modules: idempotent configuration (Lab, 5 h)\n- LAB-088 Templates and roles: build the enterprise automation repository (Lab, 6 h)\n\n### MOD-35 Network Configuration Management\n\nTopics: Configuration backup; Version control; Change management; Configuration comparison; Configuration drift; Standard configuration; Golden configuration; Rollback\n\n- THY-038 Change management, golden configuration and rollback (Theory, 2 h)\n- PROJECT-003 Automation project 1: automated MikroTik configuration backup (Project, 5 h)\n- PROJECT-004 Automation project 2: automated VLAN deployment (Project, 5 h)\n- PROJECT-005 Automation project 3: automated firewall deployment (Project, 6 h)\n- PROJECT-006 Automation project 4: automated VPN configuration (Project, 5 h)\n- PROJECT-007 Automation project 5: Ansible-based multi-router configuration (Project, 6 h)\n- PROJECT-008 Automation project 6: network monitoring automation (Project, 5 h)\n- PROJECT-009 Automation project 7: configuration drift detection (Project, 5 h)\n- PROJECT-010 Automation project 8: MikroTik security audit automation (Project, 5 h)\n- ASM-016 Phase 16 assessment: automation practical (Assessment, 3 h)\n\n## Phase 17 - Enterprise Architecture\n\n### MOD-36 Enterprise Network Architecture\n\nTopics: Core; Distribution; Access; Collapsed core; Spine-leaf concepts; Data center networking; Branch networks; HQ; WAN; Internet edge; DMZ; Management network; Server network; User network; Guest network; IoT network; SD-WAN concepts\n\n- THY-039 Hierarchical design: core, distribution, access and collapsed core (Theory, 3 h)\n- ASG-005 Enterprise architecture design document (Assignment, 5 h)\n\n### MOD-37 Campus Network Design\n\nTopics: Campus design with dual ISP, dual edge routers, firewall, core, access, users, servers and Wi-Fi; VLANs; Routing; Redundancy; Monitoring; Security\n\n- LAB-089 Enterprise Network (Lab, 8 h)\n- PROJECT-011 Enterprise Campus Network (Project, 10 h)\n\n### MOD-38 Branch Network Design\n\nTopics: HQ with four branches and cloud; Site-to-site VPN; OSPF; Failover; Centralized management; Monitoring; Security\n\n- ASG-006 Branch standard design (Assignment, 3 h)\n- PROJECT-012 Multi-Branch Enterprise (Project, 10 h)\n\n### MOD-39 Data Center Networking\n\nTopics: Data center architecture; VLAN; VXLAN concepts; Spine-leaf concepts; Redundancy; LACP; VRRP; Routing; Load balancing; Firewall segmentation; Monitoring\n\n- THY-040 Data center designs: three-tier, spine-leaf and VXLAN concepts (Theory, 3 h)\n- PROJECT-013 Secure Data Center Network (Project, 10 h)\n- ASM-017 Phase 17 assessment: enterprise architecture design (Assessment, 3 h)\n\n## Phase 18 - Cloud Networking\n\n### MOD-40 AWS Networking\n\nTopics: VPC; Subnets; Route tables; Internet Gateway; NAT Gateway; Security Groups; NACL; VPN; Transit Gateway concepts\n\n- THY-041 AWS networking building blocks (Theory, 3 h)\n- LAB-090 Build a VPC with public and private subnets (Lab, 4 h)\n- LAB-091 MikroTik to AWS site-to-site VPN (Lab, 5 h)\n\n### MOD-41 Azure Networking\n\nTopics: VNet; Subnets; NSG; Route tables; VPN Gateway; Peering\n\n- THY-042 Azure networking building blocks (Theory, 2 h)\n- LAB-092 Build a VNet with NSGs and peering (Lab, 4 h)\n- LAB-093 MikroTik to Azure site-to-site VPN (Lab, 4 h)\n- PROJECT-014 Hybrid Cloud Network (Project, 8 h)\n- ASM-018 Phase 18 assessment: cloud networking (Assessment, 2 h)\n\n## Phase 19 - Advanced Networking\n\n### MOD-42 IPv6 on MikroTik\n\nTopics: IPv6 addressing; Global unicast; Link-local; Multicast; SLAAC; DHCPv6; NDP; IPv6 routing; IPv6 firewall; Dual-stack; IPv6 troubleshooting\n\n- LAB-094 IPv6 addressing, SLAAC and NDP (Lab, 4 h)\n- LAB-095 DHCPv6 and prefix delegation (Lab, 3 h)\n- LAB-096 IPv6 routing with OSPFv3 and dual-stack (Lab, 4 h)\n- LAB-097 IPv6 firewall (Lab, 4 h)\n- TSH-024 Scenario 24: IPv6 hosts get no address or no route (Troubleshooting, 2 h)\n\n### MOD-43 VRF\n\nTopics: VRF fundamentals; Routing tables; Network isolation; Management VRF; Customer VRF; Multi-tenant networking\n\n- THY-043 VRF fundamentals (Theory, 2 h)\n- LAB-098 Customer VRFs with overlapping addresses (Lab, 4 h)\n- LAB-099 Management VRF and controlled route leaking (Lab, 4 h)\n\n### MOD-44 MPLS\n\nTopics: MPLS; Labels; LSP; LDP; MPLS VPN; Provider networks; PE; P; CE; Traffic engineering concepts\n\n- THY-044 MPLS concepts: labels, LSP, LDP, PE, P and CE (Theory, 3 h)\n- LAB-100 MPLS with LDP (Lab, 4 h)\n- LAB-101 Layer 3 VPN with VRF and BGP (Lab, 5 h)\n\n### MOD-45 ISP Networking\n\nTopics: ISP architecture; BGP; ASN; Peering; Transit; IP allocation; Route filtering; RPKI concepts; IPv6; CGNAT concepts; Traffic engineering\n\n- THY-045 ISP architecture, address allocation, RPKI and CGNAT concepts (Theory, 3 h)\n- PROJECT-015 MikroTik ISP Network (Project, 12 h)\n\n### MOD-46 Network Troubleshooting\n\nTopics: Systematic troubleshooting from layer 1 to layer 7; Torch; Packet Sniffer; Connection tracking; RouterOS logs; Interface, VLAN, bridge, routing, OSPF, BGP, NAT, firewall, VPN, DNS, DHCP, MTU, performance, CPU, memory, packet loss and asymmetric routing problems\n\n- THY-046 Systematic troubleshooting method (Theory, 2 h)\n- LAB-102 RouterOS troubleshooting tools: Torch, Packet Sniffer, connection tracking, logs, profiler (Lab, 4 h)\n- TSH-025 Scenario 25: interface and link problem (Troubleshooting, 2 h)\n- TSH-026 Scenario 26: bridge and VLAN filtering lock-out (Troubleshooting, 2 h)\n- TSH-027 Scenario 27: NAT and firewall interaction (Troubleshooting, 3 h)\n- TSH-028 Scenario 28: intermittent connectivity across sites (Troubleshooting, 3 h)\n- TSH-029 Scenario 29: memory exhaustion and connection table growth (Troubleshooting, 3 h)\n- TSH-030 Scenario 30: application slow for one site (Troubleshooting, 3 h)\n- TSH-031 Scenario 31: multi-fault network (Troubleshooting, 4 h)\n- ASM-019 Troubleshooting exam: broken network environments (Assessment, 4 h)\n\n## Phase 20 - Enterprise Capstone\n\n### MOD-47 Enterprise Network Engineering Capstone\n\nTopics: Dual ISP; Edge routers; Firewall; Core layer; Servers, Users and Wi-Fi VLANs; Security zone; Monitoring and SIEM; OSPF; BGP; Inter-VLAN routing; NAT; VPN; QoS; VRRP; Logging; Ansible automation; Backup; Documentation\n\n- CAP-001 Business and network requirements (Capstone, 4 h)\n- CAP-002 IP addressing plan, VLAN plan and topologies (Capstone, 6 h)\n- CAP-003 Routing, firewall, VPN, high-availability and security design (Capstone, 8 h)\n- CAP-004 Monitoring and automation design (Capstone, 4 h)\n- CAP-005 Build: edge, dual ISP, BGP, NAT and firewall (Capstone, 10 h)\n- CAP-006 Build: core, VLANs, inter-VLAN routing, OSPF, VRRP and Wi-Fi (Capstone, 10 h)\n- CAP-007 Build: VPN, QoS and security zone (Capstone, 8 h)\n- CAP-008 Build: monitoring, logging and dashboards (Capstone, 6 h)\n- CAP-009 Build: Ansible playbooks, backup and drift detection (Capstone, 8 h)\n- CAP-010 Test results and troubleshooting report (Capstone, 6 h)\n- CAP-011 Network documentation and disaster recovery plan (Capstone, 6 h)\n- CAP-012 Final technical report, executive architecture document and presentation (Capstone, 6 h)\n- ASM-020 Final assessment (Assessment, 3 h)\n\n### MOD-48 Career Preparation\n\nTopics: Network Engineer, MikroTik Engineer, NOC Engineer, Network Administrator, Network Security Engineer, Infrastructure Engineer, Network Automation Engineer and Cloud Network Engineer interviews\n\n- ASG-007 Portfolio: repository, lab write-ups and project descriptions (Assignment, 4 h)\n- ASG-008 Interview bank: networking and MikroTik questions (Assignment, 4 h)\n- ASG-009 Interview bank: routing, OSPF, BGP, firewall and VPN scenarios (Assignment, 4 h)\n- ASG-010 Interview bank: troubleshooting, design and automation (Assignment, 4 h)\n- ASM-021 Mock technical interview and live troubleshooting (Assessment, 3 h)\n",
   "parent": "Wiki"
  }
 ]
}
