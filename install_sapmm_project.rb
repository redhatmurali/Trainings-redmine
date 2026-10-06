# SAP MM Materials Management Complete Training - one-shot Redmine installer
#
# Put this file and sapmm_issues.csv in the same folder. Run on the Redmine server,
# from the Redmine root directory, as the Redmine OS user:
#
#   STUDENTS=alice,bob INSTRUCTORS=admin \
#     bundle exec rails runner -e production /path/to/install_sapmm_project.rb
#
# Environment variables (all optional):
#   CSV            path to sapmm_issues.csv (default: same folder as this script)
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
csv_path   = File.join(course_dir, 'sapmm_issues.csv') if csv_path.empty?
halt("not found: #{csv_path} (set CSV=/path/to/sapmm_issues.csv)") unless File.file?(csv_path)

# The project definition (fields, queries, wiki pages) is embedded at the end of this file.
embedded = File.read(File.expand_path(__FILE__), :encoding => 'utf-8').split("\n__END__\n", 2)[1]
halt('embedded project definition missing from this script') if embedded.to_s.strip.empty?
course = JSON.parse(embedded)
$tag   = course['tag'].to_s.empty? ? 'course' : course['tag']
rows   = CSV.read(csv_path, :headers => true, :encoding => 'bom|utf-8').map(&:to_h)
halt('sapmm_issues.csv is empty') if rows.empty?
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
 "tag": "sapmm",
 "project": {
  "name": "SAP MM — Materials Management Complete Training",
  "identifier": "sap-mm-complete-training",
  "description": "SAP Materials Management programme from basic business knowledge to SAP MM / S/4HANA procurement consultant: foundation, organizational structure, master data, purchasing, inventory, invoice verification, valuation, special procurement, integration, S/4HANA, testing, migration, implementation, production support, troubleshooting, real-world projects and an enterprise capstone, in 42 modules. Every topic follows Business Concept -> SAP Concept -> Configuration -> Master Data -> Transaction -> Integration -> Testing -> Troubleshooting -> Real-World Scenario -> Project. One shared project; every student has a personal copy of each issue."
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
   "name": "Topic",
   "kind": "container"
  },
  {
   "name": "Theory",
   "kind": "work"
  },
  {
   "name": "Configuration Lab",
   "kind": "work"
  },
  {
   "name": "Business Process Lab",
   "kind": "work"
  },
  {
   "name": "Practical Exercise",
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
   "name": "Troubleshooting Incident",
   "kind": "work"
  },
  {
   "name": "Real-World Project",
   "kind": "work"
  },
  {
   "name": "Documentation",
   "kind": "work"
  },
  {
   "name": "Interview Preparation",
   "kind": "work"
  },
  {
   "name": "Capstone Task",
   "kind": "work"
  },
  {
   "name": "Defect",
   "kind": "work"
  },
  {
   "name": "Change Request",
   "kind": "work"
  },
  {
   "name": "Production Incident",
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
  "Configuration",
  "Troubleshooting",
  "Documentation",
  "Testing",
  "Review",
  "Business Process",
  "Master Data",
  "Interview Preparation"
 ],
 "versions": [
  "V01 - SAP Foundation",
  "V02 - MM Core",
  "V03 - Procurement",
  "V04 - Inventory",
  "V05 - Valuation",
  "V06 - Invoice Verification",
  "V07 - Special Procurement",
  "V08 - Integration",
  "V09 - S/4HANA",
  "V10 - Testing & Migration",
  "V11 - Production Support",
  "V12 - Advanced Consulting",
  "V13 - Capstone"
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
    "Level 1 - Foundation",
    "Level 2 - SAP MM Core",
    "Level 3 - Advanced SAP MM",
    "Level 4 - Expert SAP MM Consulting"
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
   "name": "SAP Area",
   "format": "list",
   "trackers": "all",
   "csv": "SAP Area"
  },
  {
   "name": "Business Process",
   "format": "list",
   "trackers": "all",
   "csv": "Business Process",
   "values": [
    "None",
    "Procure to Pay",
    "Source to Pay",
    "Inventory Management",
    "Invoice Verification",
    "Subcontracting",
    "Consignment",
    "Stock Transfer",
    "Service Procurement",
    "MRP Procurement",
    "Physical Inventory",
    "Period-End Closing"
   ]
  },
  {
   "name": "Configuration Required",
   "format": "bool",
   "trackers": "work",
   "csv": "Configuration Required"
  },
  {
   "name": "Integration Area",
   "format": "list",
   "trackers": "all",
   "csv": "Integration Area",
   "values": [
    "None",
    "FI",
    "CO",
    "SD",
    "PP",
    "QM",
    "WM/EWM",
    "Ariba"
   ]
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
   "name": "Assessment Required",
   "format": "bool",
   "trackers": "work",
   "csv": "Assessment Required"
  },
  {
   "name": "Interview Topic",
   "format": "list",
   "trackers": "all",
   "csv": "Interview Topic",
   "values": [
    "Basic MM",
    "Procurement",
    "Purchasing Configuration",
    "Inventory",
    "Invoice Verification",
    "Valuation",
    "Account Determination",
    "Integration",
    "S/4HANA",
    "Scenario-Based",
    "Production Support",
    "Troubleshooting",
    "Consultant-Level",
    "HR"
   ]
  },
  {
   "name": "Project",
   "format": "list",
   "trackers": "work",
   "csv": "Project Name"
  },
  {
   "name": "Environment",
   "format": "list",
   "trackers": "all",
   "csv": "Environment"
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
    "S/4HANA only"
   ]
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
   "name": "Business Scenario",
   "format": "string",
   "trackers": "work",
   "csv": "Business Scenario"
  },
  {
   "name": "Transaction Code",
   "format": "list",
   "multiple": true,
   "trackers": "all",
   "csv": "Transaction Code",
   "sort": true
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
   "name": "Score",
   "format": "int",
   "trackers": [
    "Assessment",
    "Real-World Project",
    "Capstone Task"
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
      "tracker:Epic+Module+Topic"
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
      "tracker:Epic+Module+Topic"
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
   "name": "Dashboard: course completion",
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
      "tracker:Epic+Module+Topic"
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
   "name": "Dashboard: topic completion",
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
      "tracker:Topic"
     ]
    ]
   ],
   "columns": [
    "cf:Curriculum ID",
    "subject",
    "status",
    "done_ratio"
   ],
   "group_by": "cf:Module",
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
      "tracker:Configuration Lab+Business Process Lab"
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
    "cf:Score"
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
   "name": "Dashboard: project status",
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
      "tracker:Real-World Project"
     ]
    ]
   ],
   "columns": [
    "cf:Curriculum ID",
    "subject",
    "status",
    "cf:Score",
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
    "cf:Score",
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
   "name": "Dashboard: open issues",
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
      "tracker:Epic+Module+Topic"
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
   "name": "Dashboard: troubleshooting incidents",
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
      "tracker:Interview Preparation"
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
   "name": "Dashboard: configuration progress",
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
     "cf:Configuration Required",
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
      "tracker:Epic+Module+Topic"
     ]
    ],
    [
     "status_id",
     "*",
     null
    ],
    [
     "cf:ECC/S4HANA",
     "=",
     [
      "S/4HANA only",
      "ECC and S/4HANA (changed in S/4HANA)"
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
   "name": "Dashboard: by SAP area",
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
      "tracker:Epic+Module+Topic"
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
   "name": "Dashboard: by business process",
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
      "tracker:Epic+Module+Topic"
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
   "group_by": "cf:Business Process",
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
   "name": "Dashboard: by integration area",
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
      "tracker:Epic+Module+Topic"
     ]
    ],
    [
     "status_id",
     "*",
     null
    ],
    [
     "cf:Integration Area",
     "!",
     [
      "None"
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
   "group_by": "cf:Integration Area",
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
   "name": "Dashboard: defects and change requests",
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
      "tracker:Defect+Change Request"
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
      "tracker:Epic+Module+Topic"
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
      "tracker:Epic+Module+Topic"
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
      "MM-LAB-001"
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
      "tracker:Assessment+Real-World Project+Capstone Task"
     ]
    ]
   ],
   "columns": [
    "cf:Curriculum ID",
    "subject",
    "assigned_to",
    "status",
    "cf:Score"
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
   "name": "Instructor: incidents to prepare",
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
      "tracker:Troubleshooting Incident+Production Incident"
     ]
    ]
   ],
   "columns": [
    "cf:Curriculum ID",
    "subject",
    "assigned_to"
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
   "text": "# SAP MM - Materials Management Complete Training\n\nSAP Materials Management programme from basic business knowledge to SAP MM / S/4HANA procurement consultant: foundation, organizational structure, master data, purchasing, inventory, invoice verification, valuation, special procurement, integration, S/4HANA, testing, migration, implementation, production support, troubleshooting, real-world projects and an enterprise capstone, in 42 modules. Every topic follows Business Concept -> SAP Concept -> Configuration -> Master Data -> Transaction -> Integration -> Testing -> Troubleshooting -> Real-World Scenario -> Project. One shared project; every student has a personal copy of each issue.\n\n## How to work an issue\n\n1. Open your next issue from the saved query *My next tasks*.\n2. Set the status to **In Progress** and do the steps. Log time at the end of every session.\n3. Set **Testing**, check every expected result, attach the evidence.\n4. Set **Review**. The instructor sets **Completed** or **Reopened**.\n\n## Pages\n\n- [[Training_Environment]]\n- [[Course_Company]]\n- [[Organizational_Structure]]\n- [[Document_Flow]]\n- [[Lab_Format]]\n- [[Movement_Types]]\n- [[Account_Determination]]\n- [[Month_End_Closing]]\n- [[Troubleshooting_Framework]]\n- [[Document_Templates]]\n- [[Scenario_Bank]]\n- [[Interview_Bank]]\n- [[Workflow_and_Statuses]]\n- [[Assessment_and_Grading]]\n- [[Completion_Criteria]]\n- [[Dashboard_Guide]]\n- [[Skill_Matrix]]\n- [[Transaction_Code_Index]]\n- [[Fiori_App_Index]]\n- [[Module_Index]]"
  },
  {
   "title": "Training_Environment",
   "text": "# Training environment\n\n| Item | Use |\n|---|---|\n| SAP S/4HANA training system | All labs from module 01 onwards; a client with configuration rights |\n| SAP GUI | Classic transactions and customizing |\n| SAP Fiori launchpad | The app-based way of every process (module 32) |\n| Linux fundamentals | Optional background for those who also look after the training system host |\n| Database concepts | Tables, keys and joins, enough to read tables with the data browser |\n| Supporting documentation | Instructor step sheets, legacy data files, client briefs |\n| Spreadsheet templates | Configuration workbook, master-data workbook, test scripts, issue log |\n| Test data | Materials, suppliers, cost centres, production and sales orders prepared by the instructor |\n| Procurement scenarios | The scenario bank and the prepared error cases |\n\n## Documents every learner maintains\n\n- Configuration workbook\n- Master-data workbook\n- Test scripts\n- Issue log\n- RCA documents\n- Functional specifications\n- Process documentation\n- Training documentation\n\nTransaction codes in the issues are SAP GUI codes; some differ by release or have been replaced by Fiori apps in S/4HANA. Fiori app names also change between releases: check the apps reference library for your release. Integration labs with SD, PP, QM and warehouse management need data prepared by the instructor; where a component is not configured in the training system the lab is done as a documented walkthrough.",
   "parent": "Wiki"
  },
  {
   "title": "Course_Company",
   "text": "# Course company\n\n**Global Manufacturing Corporation** is the fictional company of the labs, the projects and the capstone.\n\n| Item | Design |\n|---|---|\n| Business | Manufacturer of industrial components |\n| Plants | A manufacturing plant and a distribution plant; more in the capstone |\n| Storage locations | Raw material, production, finished goods and quality hold |\n| Materials | Raw materials, semi-finished and finished products, trading goods, consumables, services |\n| Suppliers | Domestic and international suppliers, subcontractors, a consignment supplier, service contractors |\n| Procurement | Domestic and international procurement, subcontracting, consignment, services, stock transfers, MRP-driven procurement |\n| Approval | Below INR 50,000 manager; INR 50,000 to 5,00,000 department head; above INR 5,00,000 procurement head |",
   "parent": "Wiki"
  },
  {
   "title": "Organizational_Structure",
   "text": "# Organizational structure\n\n```\nClient\n   |\nCompany\n   |\nCompany Code\n   |\nPlant\n   |\nStorage Location\n```\n\n```\nClient\n   |\nPurchasing Organization\n   |\nPurchasing Group\n```\n\n| Model | Meaning | Typical use |\n|---|---|---|\n| Plant-specific purchasing | One purchasing organization per plant | Independent sites |\n| Cross-plant purchasing | One purchasing organization for several plants of a company code | Centralised buying in one legal entity |\n| Cross-company-code purchasing | Purchasing organization not assigned to a company code | Group-wide buying |\n| Reference purchasing organization | Contracts and conditions shared with other purchasing organizations | Central contracts, local call-offs |\n\nThe valuation area is the plant. A purchasing group is a buyer or buyer team and is not assigned to other units.",
   "parent": "Wiki"
  },
  {
   "title": "Document_Flow",
   "text": "# MM document flow\n\n| Document | Why it is created | Owner | Data changed | Accounting impact | First check when it breaks |\n|---|---|---|---|---|---|\n| Purchase requisition | Internal request to buy | MM | Open requirement, commitment | None | Release status, source |\n| Request for quotation | Ask suppliers for offers | MM | None | None | Supplier and deadline |\n| Quotation | Supplier's offer | MM | Price history | None | Conditions entered |\n| Purchase order | Legal order to the supplier | MM | Open order quantity, commitment | None | Supplier and material data, release |\n| Goods receipt | Goods arrive | MM | Stock, order history | Inventory debit, GR/IR credit | Period, tolerance, storage location |\n| Material document | Proof of the movement | MM | Quantity by stock type | None itself | Movement type |\n| Accounting document (receipt) | Value of the movement | FI | Ledger balances | As above | Account determination |\n| Invoice receipt | Supplier bills | MM | Order history, GR/IR | GR/IR debit, tax debit, supplier credit | Tolerances, blocks |\n| Accounting document (invoice) | Liability | FI | Supplier open item | As above | Tax code, posting period |\n| Supplier payment | Liability is paid | FI | Open item cleared | Supplier debit, bank credit | Payment block, bank data |",
   "parent": "Wiki"
  },
  {
   "title": "Lab_Format",
   "text": "# Practical lab format\n\nEvery Configuration Lab and Business Process Lab issue has these sections:\n\nLAB ID - Title - Objective - Business Scenario - Prerequisites - Required Configuration - Master Data - Procedure - Expected Result - Accounting Impact - Integration Impact - Troubleshooting - Validation - Evidence - Deliverable\n\nLab IDs are MM-LAB-001 onwards. **MM-LAB-001 - Complete Procure-to-Pay** is the first end-to-end run in module 01.\n\nPrerequisites are the *blocked by* relations of the issue; estimated and actual hours are the issue's estimated time and logged time.",
   "parent": "Wiki"
  },
  {
   "title": "Movement_Types",
   "text": "# Movement types\n\nLearn them by meaning. Reversal is normally the next number.\n\n| Type | Business meaning | Stock impact | Accounting impact |\n|---|---|---|---|\n| 101 | Goods receipt for a purchase order or order | Stock up (or consumption for account-assigned items) | Inventory or expense debit, GR/IR credit |\n| 103 / 105 | Receipt into goods receipt blocked stock / release | Not valuated until 105 | None at 103; as 101 at 105 |\n| 122 | Return delivery to supplier | Stock down | Reverse of the receipt |\n| 161 | Returns purchase order item | Stock down | Reverse of a receipt |\n| 201 | Issue to cost centre | Stock down | Consumption debit, inventory credit |\n| 221 / 241 / 261 | Issue to project / asset / order | Stock down | Consumption debit to the object, inventory credit |\n| 301 | Plant to plant, one step | Out of one plant, into the other | Inventory credit and debit, difference if prices differ |\n| 303 / 305 | Plant to plant, two steps | Stock in transfer between | Valuation at 303 |\n| 311 | Storage location to storage location | Location changes | None |\n| 321 / 322 | Quality inspection to unrestricted and back | Stock type changes | None |\n| 343 / 344 | Blocked to unrestricted and back | Stock type changes | None |\n| 331 / 333 | Sampling from quality / unrestricted stock | Stock down | Sampling expense debit, inventory credit |\n| 351 | Issue to stock in transit for a stock transport order | Into stock in transit | Plant-to-plant valuation |\n| 411 K | Consignment to own stock | Ownership changes | Inventory debit, consignment liability credit |\n| 501 | Receipt without purchase order | Stock up | Inventory debit, offsetting account credit |\n| 511 | Free-of-charge delivery | Stock up | None or revaluation for moving average price |\n| 541 | Provide components to a subcontractor | Into stock at the supplier | None |\n| 543 | Component consumption at subcontracting receipt | Stock at supplier down | Consumption debit, inventory credit |\n| 551 | Scrapping | Stock down | Scrapping expense debit, inventory credit |\n| 561 | Initial stock entry | Stock up | Inventory debit, initial stock account credit |\n| 601 | Goods issue for a sales delivery | Stock down | Cost of goods sold debit, inventory credit |\n| 701 / 702 | Physical inventory surplus / shortage | Stock adjusted | Inventory against inventory differences |",
   "parent": "Wiki"
  },
  {
   "title": "Account_Determination",
   "text": "# Automatic account determination\n\n**Material -> Valuation Class -> Transaction -> Account Determination -> G/L account**\n\nThe valuation grouping code groups valuation areas; the account category reference links material types to valuation classes; the movement type selects the transaction key and, for offsetting entries, the account grouping.\n\n| Key | Meaning | Typical posting |\n|---|---|---|\n| BSX | Inventory posting | Stock account |\n| WRX | GR/IR clearing | Goods receipt and invoice receipt |\n| PRD | Price differences | Standard price variances |\n| GBB | Offsetting entry for inventory posting | Consumption, scrapping, initial stock, inventory differences, by account grouping |\n| KBS | Account-assigned purchase order | Expense account from the order |\n| FR1 | Freight clearing | Planned delivery costs |\n| KON | Consignment payables | Withdrawals from consignment |\n| BSV | Change in stock | Subcontracting receipt |\n| FRL | External activity | Subcontracting service |\n| UMB | Revaluation | Price changes |\n| AUM | Stock transfer differences | Plant-to-plant at different prices |\n| KDM | Exchange rate differences | Invoice in foreign currency |\n| DIF | Small differences | Invoice verification |\n\nAlways confirm with the simulation in the training system; account numbers depend on the chart of accounts.",
   "parent": "Wiki"
  },
  {
   "title": "Month_End_Closing",
   "text": "# Month-end and year-end MM activities\n\n| Step | Activity | Typical transaction |\n|---|---|---|\n| 1 | Open purchase order and requisition review | ME2N, ME2M, ME5A |\n| 2 | Outstanding goods receipts and deliveries in transit | ME2N, MB5T |\n| 3 | Invoice verification complete; parked invoices | MIR6, MIR7 |\n| 4 | Blocked invoices reviewed and released | MRBR |\n| 5 | GR/IR reconciliation and account maintenance | FBL3N, MR11, F.13 |\n| 6 | Supplier reconciliation | FBL1N |\n| 7 | Physical inventory due in the period | MI24, MICN |\n| 8 | Consumption review | MC.9, KSB1 |\n| 9 | Stock valuation against ledger | MB5L, MB52 |\n| 10 | Price differences analysed | FBL3N, CKM3N |\n| 11 | Material Ledger closing (concept) | CKMLCP |\n| 12 | Close the material period and open the next | MMPV |\n\nYear end adds: annual inventory completeness, price updates for the new year, supplier balance confirmation.",
   "parent": "Wiki"
  },
  {
   "title": "Troubleshooting_Framework",
   "text": "# Troubleshooting framework\n\nProblem -> Business Impact -> Reproduce -> Check Master Data -> Check Configuration -> Check Authorization -> Check Integration -> Check Documents -> Identify Root Cause -> Fix -> Test -> Document RCA\n\n## RCA document\n\n1. Problem\n2. Business impact\n3. Steps to reproduce\n4. Checks made: master data, configuration, authorization, integration, documents\n5. Root cause\n6. Fix\n7. Test result\n8. Prevention\n\nThe programme contains 55 troubleshooting incidents and 11 production incidents. The instructor prepares each error in the training client before the issue is started.",
   "parent": "Wiki"
  },
  {
   "title": "Document_Templates",
   "text": "# Document templates\n\n**Test case:** test ID; requirement; preconditions; test steps; expected result; actual result; status; defect ID; evidence.\n\n**Functional specification:** business requirement; functional requirement; current process; future process; input; processing logic; output; business rules; error handling; security; dependencies; acceptance criteria.\n\n**Configuration workbook:** area; IMG path or app; setting and values; rationale; naming convention; unit test reference; transport.\n\n**Master-data workbook:** object; key; organizational levels; main field values; purpose.\n\n**Issue log:** date; issue; message; cause; solution; time lost.\n\n**Business requirement document:** numbered requirements; priority; owner; acceptance.\n\n**Gap analysis:** requirement; standard fit; gap; options; decision; effort.\n\n**Migration strategy:** object; source; cleansing; mapping; tool; sequence; validation; reconciliation; owner.\n\n**Cutover plan:** task; owner; start; duration; dependency; verification; fallback.\n\n**Go-live checklist:** readiness item; owner; evidence; go or no-go.\n\n**Change request:** reason; impact; risk; configuration; test plan; rollback; transport; approval.\n\n**Support runbook:** daily checks; jobs; month-end tasks; known errors; contacts; escalation.\n\n**Project explanation:** business requirement; my role; configuration; integration; testing; issue; solution; business result.",
   "parent": "Wiki"
  },
  {
   "title": "Scenario_Bank",
   "text": "# Real-world scenario bank\n\nOne hundred business scenarios, worked in the ten scenario pack assignments of module 40. For each: business impact, SAP process and documents, what to check, likely root cause or design decision, solution, prevention.\n\n1. Supplier price changed from next month; open orders must keep the old price\n2. Material unavailable at the supplier; an alternative source must be used\n3. PO price incorrect after the supplier invoice arrives\n4. Duplicate PO created for the same requisition\n5. GR quantity mismatch between delivery note and purchase order\n6. Invoice blocked for price variance at month end\n7. GR/IR mismatch because the invoice arrived before the goods\n8. Wrong valuation class found on a material that already has stock\n9. Wrong G/L account posted by a goods issue\n10. Supplier blocked for quality while orders are open\n11. Material blocked for procurement but needed urgently\n12. PO approval pending while the approver is on leave\n13. Workflow not triggered for a high-value order\n14. Stock mismatch between the system and the warehouse\n15. Physical inventory difference above the clerk's tolerance\n16. STO failure: delivery cannot be created at the supplying plant\n17. Subcontracting component missing at the supplier\n18. Consignment stock issue: withdrawals were never settled\n19. MRP does not create PR for a reorder point material\n20. Incorrect delivery date proposed in the purchase order\n21. Tax issue: invoice tax differs from the order\n22. Freight condition issue: forwarder invoice does not match the accrual\n23. Duplicate invoice received with a slightly different reference\n24. Return to supplier after the invoice was already paid\n25. Partial delivery and the supplier will not ship the rest\n26. Over-delivery that the stores want to keep\n27. Under-delivery on a critical component\n28. Wrong purchasing organization used for a plant\n29. Incorrect plant in a goods receipt\n30. Wrong storage location in a goods receipt\n31. New plant opens and must buy from existing contracts\n32. New supplier must be onboarded within a day for an urgent order\n33. Supplier changes bank details by e-mail\n34. One-time purchase from a supplier that will never be used again\n35. Buyer leaves the company; open orders must be reassigned\n36. Purchasing group structure is reorganised\n37. Material needs a new unit of measure for ordering\n38. Material is converted to batch management while stock exists\n39. Base unit of measure of a material is wrong\n40. Material created in the wrong material type\n41. Requisition raised without a material master for a new item\n42. Requisition must be split between two suppliers\n43. Urgent requirement must bypass the normal bidding process\n44. Supplier offers a volume discount above a yearly quantity\n45. Supplier quotes in a foreign currency with exchange rate risk\n46. Price must be valid per plant, not per purchasing organization\n47. Contract reaches its target value before the validity ends\n48. Contract price is renegotiated in the middle of the year\n49. Scheduling agreement supplier delivers ahead of the schedule\n50. Framework order limit is exhausted before year end\n51. Order must be sent to the supplier in two languages\n52. Supplier asks for an advance payment on a large order\n53. Order acknowledgement shows a later date than requested\n54. Incoterms change the point where ownership passes\n55. Approval threshold must differ for capital and operating purchases\n56. Order is changed after approval and must be approved again\n57. Requisition approved but budget is no longer available\n58. Goods arrive without a purchase order\n59. Goods arrive damaged and are partly rejected\n60. Goods arrive with the wrong batch or missing certificate\n61. Goods arrive after the order was closed\n62. Goods receipt was posted to the wrong purchase order\n63. Goods receipt must be reversed after the invoice was posted\n64. Free-of-charge sample delivered with an order\n65. Returnable packaging arrives with the goods\n66. Shelf life of a delivered batch is too short\n67. Stock must be moved to a new storage location during a warehouse reorganisation\n68. Stock is found in the warehouse that is not in the system\n69. Material is scrapped after a quality failure\n70. Stock must be transferred between two company codes\n71. Stock in transit is not received at the destination plant\n72. Reservation exists but stock was issued to another department\n73. Cost centre on a goods issue was wrong\n74. Negative stock is requested by the shop floor for timing reasons\n75. Cycle count finds repeated differences on the same material\n76. Annual inventory must run without stopping production\n77. Invoice arrives without a purchase order reference\n78. Invoice quantity is higher than the goods received\n79. Invoice for freight comes from a different supplier than planned\n80. Supplier sends a credit memo for a price correction\n81. Invoice was posted to the wrong supplier\n82. Invoice in foreign currency is paid at a different exchange rate\n83. Invoices are blocked in mass after a tolerance change\n84. Supplier wants self-billing without sending invoices\n85. Small differences on invoices should be accepted automatically\n86. Standard price of a material is clearly out of date\n87. Moving average price is distorted by a wrong goods receipt\n88. Inventory account does not agree with the stock value report\n89. Price difference account shows a large unexplained balance\n90. Same material has different values for imported and local procurement\n91. Period was not closed and postings went to the wrong month\n92. Subcontractor returns more scrap than planned\n93. Subcontractor receives components directly from another supplier\n94. Consignment price changes while stock is on site\n95. Service was performed beyond the ordered scope\n96. Service entry is rejected by the requester\n97. Third-party supplier delivers a different quantity than the customer ordered\n98. Production reports a component shortage although planning showed coverage\n99. Quality keeps stock in inspection longer than the planned lead time\n100. After go-live users report that an old transaction no longer exists",
   "parent": "Wiki"
  },
  {
   "title": "Interview_Bank",
   "text": "# Interview bank\n\nFor every question prepare: question, short answer, detailed answer, real-world example, configuration relevance and common mistake.\n\n## Basic MM (INT-001)\n\n1. What is SAP MM and where does it sit in the supply chain?\n2. What are the organizational units of MM and how are they assigned?\n3. What is the difference between master data and configuration?\n4. What is a material type and what does it control?\n5. What are the views of the material master?\n6. What is a purchasing info record?\n7. What is the difference between a plant and a storage location?\n8. What documents does a goods receipt create?\n\n## Procurement (INT-002)\n\n1. Explain the Procure-to-Pay cycle\n2. What is the difference between a requisition and a purchase order?\n3. What sources of supply exist and in which order are they determined?\n4. Contract versus scheduling agreement?\n5. What is a source list and when is it mandatory?\n6. How does quota arrangement work?\n7. What is the difference between item category and account assignment category?\n8. How do you buy a material without a material master?\n\n## Purchasing Configuration (INT-003)\n\n1. How do you create a new purchase order document type?\n2. How does the release strategy with classification work?\n3. What is the difference between release procedure and flexible workflow?\n4. How is the calculation schema determined?\n5. What is an access sequence?\n6. How do you make a field mandatory in the purchase order?\n7. How is output determined for a purchase order?\n8. What are purchasing value keys?\n\n## Inventory (INT-004)\n\n1. What is a movement type and what does it control?\n2. Difference between transfer posting and stock transfer?\n3. One-step versus two-step transfer?\n4. What stock types exist?\n5. What is goods receipt blocked stock?\n6. How is a material document cancelled?\n7. What is a reservation?\n8. Explain the physical inventory process\n\n## Invoice Verification (INT-005)\n\n1. What is the three-way match?\n2. What is goods-receipt-based invoice verification?\n3. Why is an invoice blocked and how is it released?\n4. Subsequent debit versus credit memo?\n5. Planned versus unplanned delivery costs?\n6. What is the GR/IR clearing account?\n7. What is evaluated receipt settlement?\n8. How is a posted invoice reversed?\n\n## Valuation (INT-006)\n\n1. Standard price versus moving average price?\n2. What happens to a price variance at invoice under each price control?\n3. What is split valuation?\n4. What is the valuation area?\n5. How do you change a material price?\n6. Why is the Material Ledger mandatory in S/4HANA?\n7. What is actual costing?\n8. How do you reconcile stock value with the ledger?\n\n## Account Determination (INT-007)\n\n1. Explain automatic account determination from material to account\n2. What is a valuation class?\n3. What is the account category reference?\n4. What are transaction keys? Name six\n5. What is the valuation grouping code?\n6. What is account grouping and where does it come from?\n7. How do you find the account a movement will post to?\n8. What postings occur at subcontracting goods receipt?\n\n## Integration (INT-008)\n\n1. How does MM integrate with FI?\n2. How does MM integrate with CO?\n3. How does MM integrate with SD?\n4. How does MM integrate with PP?\n5. How does MM integrate with QM?\n6. How does MM integrate with warehouse management?\n7. What is a stock transport order with delivery?\n8. What is third-party procurement?\n\n## S/4HANA (INT-009)\n\n1. What changed in MM from ECC to S/4HANA?\n2. What is the business partner and why is it mandatory?\n3. What changed in the inventory data model?\n4. What is flexible workflow?\n5. What changed in output management?\n6. What is MRP Live?\n7. What are lean services?\n8. Name ten procurement Fiori apps and their roles\n\n## Scenario-Based (INT-010)\n\n1. A plant needs a new approval level: what do you do?\n2. The client wants one purchasing department for five plants: how do you design it?\n3. Two suppliers share volume 70/30: how?\n4. Stock is physically present but cannot be issued: why?\n5. The client wants freight added to inventory value: how?\n6. Month-end GR/IR balance is high: what do you do?\n7. A supplier keeps stock at the client's site: which process?\n8. The client buys services monthly at varying quantity: which design?\n\n## Production Support (INT-011)\n\n1. How do you prioritise tickets?\n2. Describe a critical incident you solved\n3. What is the difference between incident, problem and change?\n4. How do you move a fix to production?\n5. What do you do when you cannot reproduce an error?\n6. How do you communicate with a business user during an outage?\n7. What is in a root cause analysis?\n8. What are your daily checks?\n\n## Troubleshooting (INT-012)\n\n1. Purchase order cannot be created: where do you look?\n2. Goods receipt fails: what are the common causes?\n3. An invoice is blocked: how do you analyse it?\n4. A wrong account was posted: how do you find the cause?\n5. Planning creates no requisition: why?\n6. Release strategy is not triggered: why?\n7. Stock transport order delivery cannot be created: why?\n8. Price in the order is wrong: how do you trace it?\n\n## Consultant-Level (INT-013)\n\n1. How do you run a fit-to-standard workshop?\n2. How do you decide between configuration and development?\n3. How do you design the enterprise structure for a group?\n4. How do you plan MM cutover?\n5. How do you approach data migration of stock?\n6. What are the main controls in Procure-to-Pay?\n7. What is clean core?\n8. How does Ariba fit with MM?\n\n## HR (INT-014)\n\n1. Tell me about yourself\n2. Why SAP MM?\n3. Describe a conflict with a business user\n4. How do you handle pressure at month end?\n5. What is your biggest mistake in a system and what did you learn?\n6. Why should we hire you?\n7. Where do you see yourself in three years?\n8. What are your salary expectations?\n",
   "parent": "Wiki"
  },
  {
   "title": "Workflow_and_Statuses",
   "text": "# Workflow and statuses\n\n| Status | Meaning | Course workflow stage |\n|---|---|---|\n| New | Template or unassigned | New |\n| Assigned | Belongs to a student, not started | Lab Pending |\n| In Progress | Being worked on | Learning / Lab In Progress |\n| Blocked | Cannot continue; a note states the blocker | - |\n| Testing | Steps done; student validates the expected result and collects evidence | Testing |\n| Review | Submitted to the instructor | Completed (by the student) |\n| Completed | Approved by the instructor | Reviewed |\n| Reopened | Changes requested | - |\n| Rejected | Waived or not applicable (instructor only) | - |\n\nThe statuses are shared with the other training projects on this Redmine. Prerequisites are *blocked by* relations: an issue cannot be closed while its blocker is open.\n\nStatus, Estimated Hours, Actual Hours and Prerequisite are Redmine's own fields: status, estimated time, spent time and the blocked-by relations.",
   "parent": "Wiki"
  },
  {
   "title": "Assessment_and_Grading",
   "text": "# Assessment and grading\n\n| Group | Covers |\n|---|---|\n| Foundation assessments | SAP basics, procurement basics, accounting basics |\n| Core assessments | Material master, supplier master, purchasing, inventory, invoice verification |\n| Advanced assessments | Valuation, account determination, special procurement, integration, S/4HANA |\n| Expert assessments | Implementation, migration, testing, production support, troubleshooting, solution design |\n| Projects and capstone | Nine real-world projects and the capstone, each scored 0-100 |\n\nPass mark 70, recorded in the Score field. Programme grade: assessments 30 %, projects and incidents 30 %, capstone 40 %.",
   "parent": "Wiki"
  },
  {
   "title": "Completion_Criteria",
   "text": "# Completion criteria\n\nThe course is complete only when the learner has:\n\n- Completed all foundation modules\n- Completed SAP MM core modules\n- Completed procurement labs\n- Completed inventory labs\n- Completed invoice verification\n- Understood valuation\n- Understood automatic account determination\n- Completed integration labs\n- Completed S/4HANA modules\n- Completed Fiori exercises\n- Completed testing exercises\n- Completed migration exercise\n- Completed production-support exercises\n- Solved troubleshooting scenarios\n- Completed real-world projects\n- Completed interview preparation\n- Completed final enterprise capstone\n\nIn Redmine: all 42 gate reviews are Completed.",
   "parent": "Wiki"
  },
  {
   "title": "Dashboard_Guide",
   "text": "# Dashboard guide\n\nThe dashboard is the set of saved queries in the issue list sidebar. Add them to *My page* as custom query blocks.\n\n| Dashboard item | Saved query |\n|---|---|\n| Course completion % | Dashboard: course completion |\n| Level completion | Dashboard: level completion |\n| Module completion | Dashboard: module completion |\n| Lab completion | Dashboard: lab completion |\n| Assessment score | Dashboard: assessment scores |\n| Project status | Dashboard: project status |\n| Capstone progress | Dashboard: capstone progress |\n| Open issues | Dashboard: open issues |\n| Troubleshooting incidents | Dashboard: troubleshooting incidents |\n| Interview readiness | Dashboard: interview readiness |\n| Configuration progress | Dashboard: configuration progress |\n| S/4HANA progress | Dashboard: S/4HANA progress |\n\nFor % done to follow the status, set *Administration > Settings > Issue tracking > Calculate the issue done ratio* to *Use the issue status* (global setting).",
   "parent": "Wiki"
  },
  {
   "title": "Skill_Matrix",
   "text": "# Skill matrix\n\n| SAP area | Level | Topics | Tasks | Hours |\n|---|---|---|---|---|\n| Foundation | Level 1 - Foundation | TOPIC-001, TOPIC-002, TOPIC-003, TOPIC-004, TOPIC-005, TOPIC-006, TOPIC-007 | 17 | 44 |\n| Enterprise Structure | Level 2 - SAP MM Core | TOPIC-008 | 8 | 18 |\n| Material Master | Level 2 - SAP MM Core | TOPIC-009, TOPIC-010 | 13 | 27 |\n| Supplier Master | Level 2 - SAP MM Core | TOPIC-011, TOPIC-012 | 9 | 18 |\n| Purchasing | Level 2 - SAP MM Core | TOPIC-013, TOPIC-014, TOPIC-015, TOPIC-016, TOPIC-017, TOPIC-018, TOPIC-019, TOPIC-020, TOPIC-036 | 58 | 129 |\n| Inventory | Level 2 - SAP MM Core | TOPIC-021, TOPIC-022, TOPIC-023, TOPIC-024, TOPIC-025, TOPIC-026, TOPIC-027 | 44 | 97 |\n| Invoice Verification | Level 2 - SAP MM Core | TOPIC-028 | 11 | 27 |\n| Valuation | Level 2 - SAP MM Core | TOPIC-029, TOPIC-030, TOPIC-031 | 20 | 47 |\n| Special Procurement | Level 2 - SAP MM Core | TOPIC-032, TOPIC-033, TOPIC-034, TOPIC-035 | 13 | 31 |\n| Integration | Level 2 - SAP MM Core | TOPIC-037, TOPIC-038, TOPIC-039, TOPIC-040, TOPIC-041, TOPIC-042, TOPIC-043 | 26 | 54 |\n| S/4HANA | Level 3 - Advanced SAP MM | TOPIC-044, TOPIC-045 | 6 | 15 |\n| Fiori | Level 3 - Advanced SAP MM | TOPIC-046 | 6 | 13 |\n| Analytics | Level 3 - Advanced SAP MM | TOPIC-047, TOPIC-048 | 7 | 18 |\n| Security | Level 3 - Advanced SAP MM | TOPIC-049 | 5 | 10 |\n| Testing | Level 3 - Advanced SAP MM | TOPIC-050 | 8 | 24 |\n| Migration | Level 3 - Advanced SAP MM | TOPIC-051 | 8 | 23 |\n| Implementation | Level 3 - Advanced SAP MM | TOPIC-052, TOPIC-053, TOPIC-054 | 11 | 33 |\n| Production Support | Level 3 - Advanced SAP MM | TOPIC-055 | 19 | 31 |\n| Troubleshooting | Level 3 - Advanced SAP MM | TOPIC-056 | 20 | 27 |\n| Projects | Level 3 - Advanced SAP MM | TOPIC-057, TOPIC-058, TOPIC-059, TOPIC-060 | 27 | 91 |\n| Expert Consulting | Level 4 - Expert SAP MM Consulting | TOPIC-061, TOPIC-062, TOPIC-063, TOPIC-064 | 10 | 34 |\n| Career | Level 4 - Expert SAP MM Consulting | TOPIC-065, TOPIC-066 | 18 | 41 |\n| Capstone | Level 4 - Expert SAP MM Consulting | TOPIC-067 | 17 | 104 |",
   "parent": "Wiki"
  },
  {
   "title": "Transaction_Code_Index",
   "text": "# Transaction code index\n\nGrouped as in the transaction reference tasks of module 41, where the student writes for each code: purpose, business scenario, input, output, related transaction and S/4HANA or Fiori alternative.\n\n## Master Data\n\n| Transaction | Topics |\n|---|---|\n| AC03 | TOPIC-035 |\n| BP | TOPIC-006, TOPIC-011, TOPIC-012, TOPIC-044, TOPIC-051, TOPIC-067 |\n| CS01 | TOPIC-032 |\n| CS03 | TOPIC-041 |\n| KA03 | TOPIC-039 |\n| KO03 | TOPIC-039 |\n| KS03 | TOPIC-039 |\n| ME01 | TOPIC-013 |\n| ME03 | TOPIC-013 |\n| ME11 | TOPIC-013, TOPIC-019, TOPIC-033 |\n| ME12 | TOPIC-013 |\n| ME13 | TOPIC-013, TOPIC-051 |\n| ME61 | TOPIC-012, TOPIC-045 |\n| ME63 | TOPIC-012 |\n| ME65 | TOPIC-012 |\n| MEK1 | TOPIC-019 |\n| MEK2 | TOPIC-019 |\n| MEK3 | TOPIC-019 |\n| MEQ1 | TOPIC-013 |\n| MEQ3 | TOPIC-013 |\n| MK03 | TOPIC-011 |\n| MK05 | TOPIC-012 |\n| MM01 | TOPIC-006, TOPIC-010, TOPIC-030, TOPIC-067 |\n| MM02 | TOPIC-010, TOPIC-037, TOPIC-042 |\n| MM03 | TOPIC-006, TOPIC-010, TOPIC-030, TOPIC-051 |\n| MM06 | TOPIC-010 |\n| MM60 | TOPIC-010 |\n| MSC1N | TOPIC-010 |\n| MSC3N | TOPIC-023 |\n| XK03 | TOPIC-011 |\n| XK05 | TOPIC-012 |\n\n## Purchasing\n\n| Transaction | Topics |\n|---|---|\n| MD01N | TOPIC-037, TOPIC-044, TOPIC-057 |\n| MD03 | TOPIC-037 |\n| MD04 | TOPIC-037, TOPIC-040, TOPIC-041, TOPIC-056 |\n| MD05 | TOPIC-037 |\n| MD61 | TOPIC-037 |\n| ME21N | TOPIC-006, TOPIC-014, TOPIC-015, TOPIC-016, TOPIC-017, TOPIC-019, TOPIC-026, TOPIC-032, TOPIC-033, TOPIC-034, TOPIC-035, TOPIC-036, TOPIC-039, TOPIC-045, TOPIC-050, TOPIC-057, TOPIC-067 |\n| ME22N | TOPIC-016 |\n| ME23N | TOPIC-006, TOPIC-007, TOPIC-016, TOPIC-017, TOPIC-023, TOPIC-028, TOPIC-035, TOPIC-050, TOPIC-055, TOPIC-056, TOPIC-060 |\n| ME28 | TOPIC-020 |\n| ME29N | TOPIC-020 |\n| ME2O | TOPIC-032, TOPIC-057, TOPIC-060 |\n| ME31K | TOPIC-036, TOPIC-045, TOPIC-057 |\n| ME31L | TOPIC-036 |\n| ME32K | TOPIC-036 |\n| ME33K | TOPIC-036 |\n| ME38 | TOPIC-036 |\n| ME41 | TOPIC-015, TOPIC-045, TOPIC-057 |\n| ME42 | TOPIC-015 |\n| ME47 | TOPIC-015, TOPIC-057 |\n| ME49 | TOPIC-015, TOPIC-057 |\n| ME51N | TOPIC-006, TOPIC-013, TOPIC-014, TOPIC-050, TOPIC-057 |\n| ME52N | TOPIC-014, TOPIC-034, TOPIC-040 |\n| ME53N | TOPIC-014 |\n| ME54N | TOPIC-014, TOPIC-020 |\n| ME55 | TOPIC-014, TOPIC-020 |\n| ME57 | TOPIC-013, TOPIC-014, TOPIC-037 |\n| ME59N | TOPIC-014 |\n| ME84 | TOPIC-036 |\n| ME9E | TOPIC-036 |\n| ME9F | TOPIC-016, TOPIC-018 |\n\n## Inventory\n\n| Transaction | Topics |\n|---|---|\n| /SCWM/MON | TOPIC-043 |\n| /SCWM/PRDI | TOPIC-043 |\n| CO03 | TOPIC-041 |\n| CO09 | TOPIC-040 |\n| CO11N | TOPIC-041 |\n| LS26 | TOPIC-043 |\n| LT01 | TOPIC-043 |\n| LT0A | TOPIC-043 |\n| MB03 | TOPIC-006, TOPIC-007, TOPIC-021, TOPIC-023, TOPIC-024, TOPIC-060 |\n| MB21 | TOPIC-021, TOPIC-024 |\n| MB22 | TOPIC-021 |\n| MB26 | TOPIC-041 |\n| MIGO | TOPIC-006, TOPIC-019, TOPIC-021, TOPIC-022, TOPIC-023, TOPIC-024, TOPIC-025, TOPIC-026, TOPIC-029, TOPIC-030, TOPIC-032, TOPIC-033, TOPIC-034, TOPIC-036, TOPIC-038, TOPIC-040, TOPIC-041, TOPIC-042, TOPIC-043, TOPIC-044, TOPIC-050, TOPIC-051, TOPIC-056, TOPIC-057, TOPIC-067 |\n| ML81N | TOPIC-035, TOPIC-057 |\n| ML84 | TOPIC-035 |\n| QA11 | TOPIC-042 |\n| QA32 | TOPIC-042 |\n| QE51N | TOPIC-042 |\n| QI01 | TOPIC-042 |\n| VL02N | TOPIC-026 |\n| VL03N | TOPIC-040, TOPIC-060 |\n| VL10B | TOPIC-026, TOPIC-057 |\n| VL31N | TOPIC-043 |\n| VL32N | TOPIC-043 |\n\n## Invoice Verification\n\n| Transaction | Topics |\n|---|---|\n| F.13 | TOPIC-038 |\n| F110 | TOPIC-038, TOPIC-057 |\n| FBL1N | TOPIC-028, TOPIC-038, TOPIC-058 |\n| MIR4 | TOPIC-007, TOPIC-028, TOPIC-060 |\n| MIR7 | TOPIC-028 |\n| MIRA | TOPIC-028 |\n| MIRO | TOPIC-006, TOPIC-026, TOPIC-028, TOPIC-029, TOPIC-030, TOPIC-032, TOPIC-034, TOPIC-035, TOPIC-038, TOPIC-045, TOPIC-050, TOPIC-056, TOPIC-057, TOPIC-067 |\n| MR11 | TOPIC-038, TOPIC-058 |\n| MR8M | TOPIC-028 |\n| MRBR | TOPIC-028, TOPIC-058 |\n| MRKO | TOPIC-033, TOPIC-057, TOPIC-060 |\n\n## Physical Inventory\n\n| Transaction | Topics |\n|---|---|\n| MI01 | TOPIC-027, TOPIC-057 |\n| MI02 | TOPIC-027 |\n| MI04 | TOPIC-027 |\n| MI05 | TOPIC-027 |\n| MI07 | TOPIC-027, TOPIC-057 |\n| MI11 | TOPIC-027 |\n| MI20 | TOPIC-027 |\n| MI21 | TOPIC-027 |\n| MI24 | TOPIC-027, TOPIC-058 |\n| MI31 | TOPIC-027 |\n| MICN | TOPIC-027 |\n\n## Valuation\n\n| Transaction | Topics |\n|---|---|\n| CKM3N | TOPIC-030, TOPIC-031, TOPIC-058 |\n| CKMLCP | TOPIC-031 |\n| FS00 | TOPIC-029 |\n| MB5L | TOPIC-030, TOPIC-047, TOPIC-058 |\n| MMPV | TOPIC-008, TOPIC-031, TOPIC-058 |\n| MR21 | TOPIC-030, TOPIC-031 |\n| MR22 | TOPIC-030 |\n\n## Reporting\n\n| Transaction | Topics |\n|---|---|\n| FAGLB03 | TOPIC-038 |\n| FBL3N | TOPIC-038, TOPIC-048, TOPIC-058 |\n| KE5Z | TOPIC-039 |\n| KOB1 | TOPIC-039 |\n| KSB1 | TOPIC-024, TOPIC-039 |\n| MB25 | TOPIC-021 |\n| MB51 | TOPIC-021, TOPIC-022, TOPIC-024, TOPIC-025, TOPIC-032, TOPIC-047, TOPIC-055, TOPIC-056 |\n| MB52 | TOPIC-021, TOPIC-047, TOPIC-051, TOPIC-058 |\n| MB53 | TOPIC-047 |\n| MB54 | TOPIC-033 |\n| MB5B | TOPIC-021, TOPIC-047, TOPIC-048, TOPIC-058 |\n| MB5M | TOPIC-047 |\n| MB5T | TOPIC-025, TOPIC-026 |\n| MB90 | TOPIC-023 |\n| MC.9 | TOPIC-047, TOPIC-048, TOPIC-058 |\n| MC46 | TOPIC-048 |\n| MC50 | TOPIC-048 |\n| ME0M | TOPIC-013 |\n| ME1E | TOPIC-015 |\n| ME1M | TOPIC-013 |\n| ME1P | TOPIC-047 |\n| ME2K | TOPIC-016, TOPIC-036, TOPIC-039, TOPIC-047 |\n| ME2L | TOPIC-016, TOPIC-047 |\n| ME2M | TOPIC-016, TOPIC-047, TOPIC-058 |\n| ME2N | TOPIC-016, TOPIC-026, TOPIC-047, TOPIC-048, TOPIC-051, TOPIC-058 |\n| ME4M | TOPIC-015 |\n| ME5A | TOPIC-014, TOPIC-047, TOPIC-048, TOPIC-051, TOPIC-058 |\n| ME80FN | TOPIC-047 |\n| ME80RN | TOPIC-036 |\n| MIR6 | TOPIC-028, TOPIC-047 |\n| MMBE | TOPIC-006, TOPIC-010, TOPIC-021, TOPIC-025, TOPIC-030, TOPIC-033, TOPIC-040, TOPIC-042 |\n\n## Configuration\n\n| Transaction | Topics |\n|---|---|\n| BUC2 | TOPIC-011 |\n| BUCF | TOPIC-011 |\n| CL02 | TOPIC-020 |\n| CL20N | TOPIC-020 |\n| CL24N | TOPIC-020 |\n| CT04 | TOPIC-020 |\n| FLVN00 | TOPIC-011 |\n| FLVN01 | TOPIC-011 |\n| FTXP | TOPIC-038 |\n| LTMOM | TOPIC-051 |\n| M/03 | TOPIC-019 |\n| M/06 | TOPIC-019 |\n| M/07 | TOPIC-019 |\n| M/08 | TOPIC-019 |\n| MIBC | TOPIC-027 |\n| MMNR | TOPIC-009 |\n| MN04 | TOPIC-018 |\n| NACE | TOPIC-018 |\n| OBYC | TOPIC-022, TOPIC-029, TOPIC-056 |\n| OMC0 | TOPIC-023 |\n| OME4 | TOPIC-008, TOPIC-018 |\n| OME9 | TOPIC-018 |\n| OMH6 | TOPIC-018 |\n| OMJJ | TOPIC-008, TOPIC-021, TOPIC-022 |\n| OMR6 | TOPIC-018, TOPIC-028 |\n| OMS2 | TOPIC-009 |\n| OMS4 | TOPIC-009 |\n| OMSF | TOPIC-009 |\n| OMSK | TOPIC-029 |\n| OMSL | TOPIC-009 |\n| OMSR | TOPIC-009 |\n| OMSY | TOPIC-008 |\n| OMWB | TOPIC-029, TOPIC-056 |\n| OMWC | TOPIC-030 |\n| OMWD | TOPIC-029 |\n| OMWM | TOPIC-008, TOPIC-029 |\n| OMWN | TOPIC-029 |\n| OX01 | TOPIC-008 |\n| OX02 | TOPIC-008 |\n| OX08 | TOPIC-008 |\n| OX09 | TOPIC-008 |\n| OX10 | TOPIC-008 |\n| OX15 | TOPIC-008 |\n| OX17 | TOPIC-008 |\n| OX18 | TOPIC-008 |\n| SCC1 | TOPIC-053 |\n| SE10 | TOPIC-052, TOPIC-053, TOPIC-055, TOPIC-056 |\n| SPRO | TOPIC-018, TOPIC-052, TOPIC-053, TOPIC-061, TOPIC-064, TOPIC-067 |\n| STMS | TOPIC-052, TOPIC-053, TOPIC-055 |\n\n## Troubleshooting\n\n| Transaction | Topics |\n|---|---|\n| PFCG | TOPIC-049 |\n| SE16N | TOPIC-044, TOPIC-055, TOPIC-064 |\n| SM21 | TOPIC-055 |\n| SM37 | TOPIC-055, TOPIC-064 |\n| ST22 | TOPIC-055 |\n| SU01 | TOPIC-049 |\n| SU3 | TOPIC-006, TOPIC-049 |\n| SU53 | TOPIC-049, TOPIC-055, TOPIC-056, TOPIC-064 |\n| SUIM | TOPIC-049 |\n| SWIA | TOPIC-020 |\n\n## Integration and other\n\n| Transaction | Topics |\n|---|---|\n| /UI2/FLP | TOPIC-046 |\n| FB03 | TOPIC-006, TOPIC-007, TOPIC-023, TOPIC-028, TOPIC-029, TOPIC-038, TOPIC-060 |\n| LTMC | TOPIC-051 |\n| VA03 | TOPIC-034, TOPIC-040 |\n| VF01 | TOPIC-026 |\n",
   "parent": "Wiki"
  },
  {
   "title": "Fiori_App_Index",
   "text": "# Fiori app index\n\nApp names as used in the issues; names and availability vary by release, so confirm in the apps reference library.\n\n| Fiori app | Topics |\n|---|---|\n| App Finder | TOPIC-006 |\n| Clear GR/IR Clearing Account | TOPIC-038, TOPIC-058 |\n| Compare Supplier Quotations | TOPIC-015 |\n| Create Physical Inventory Documents | TOPIC-027 |\n| Create Purchase Order - Advanced | TOPIC-016 |\n| Create Purchase Requisition | TOPIC-014, TOPIC-046 |\n| Create Supplier Invoice | TOPIC-028, TOPIC-046 |\n| Dead Stock Analysis | TOPIC-048 |\n| Display G/L Account Balances | TOPIC-038 |\n| Display Material Value Chain | TOPIC-030, TOPIC-031 |\n| Inventory Turnover Analysis | TOPIC-048 |\n| Manage Business Partner Master Data | TOPIC-011 |\n| Manage Material Coverage | TOPIC-037 |\n| Manage Physical Inventory Documents | TOPIC-027 |\n| Manage Product Master Data | TOPIC-010 |\n| Manage Purchase Contracts | TOPIC-036 |\n| Manage Purchase Orders | TOPIC-006, TOPIC-016, TOPIC-035, TOPIC-046 |\n| Manage Purchase Requisitions | TOPIC-014, TOPIC-046 |\n| Manage Purchasing Info Records | TOPIC-013 |\n| Manage Quota Arrangements | TOPIC-013 |\n| Manage RFQs | TOPIC-015 |\n| Manage Scheduling Agreements | TOPIC-036 |\n| Manage Service Entry Sheets - Lean Services | TOPIC-035 |\n| Manage Source Lists | TOPIC-013 |\n| Manage Sources of Supply | TOPIC-013 |\n| Manage Stock | TOPIC-021, TOPIC-023, TOPIC-024, TOPIC-046 |\n| Manage Supplier Invoices | TOPIC-028 |\n| Manage Supplier Line Items | TOPIC-038 |\n| Manage Supplier Master Data | TOPIC-011, TOPIC-046 |\n| Manage Supplier Quotations | TOPIC-015 |\n| Manage Usage Decisions | TOPIC-042 |\n| Manage Workflows for Purchase Orders | TOPIC-020 |\n| Manage Workflows for Purchase Requisitions | TOPIC-020 |\n| Material Documents Overview | TOPIC-021, TOPIC-047 |\n| Material Price Analysis | TOPIC-030, TOPIC-031 |\n| Migrate Your Data - Migration Cockpit | TOPIC-051 |\n| Monitor Material Coverage | TOPIC-037 |\n| Monitor Purchase Order Items | TOPIC-016, TOPIC-047, TOPIC-058 |\n| Monitor Purchase Requisition Items | TOPIC-047 |\n| My Home | TOPIC-006 |\n| My Inbox | TOPIC-020, TOPIC-046 |\n| My Purchase Requisitions | TOPIC-014 |\n| Overdue Purchase Order Items | TOPIC-048 |\n| Physical Inventory Document Overview | TOPIC-027 |\n| Post Goods Movement | TOPIC-021, TOPIC-024 |\n| Post Goods Receipt for Purchasing Document | TOPIC-023, TOPIC-046 |\n| Process Purchase Requisitions | TOPIC-014 |\n| Procurement Overview | TOPIC-046, TOPIC-048 |\n| Purchase Requisition Item Changes | TOPIC-048 |\n| Purchasing Spend | TOPIC-048 |\n| Record Inspection Results | TOPIC-042 |\n| Release Blocked Invoices | TOPIC-028, TOPIC-058 |\n| Schedule MRP Runs | TOPIC-037 |\n| Slow or Non-Moving Materials | TOPIC-048 |\n| Stock - Multiple Materials | TOPIC-021, TOPIC-047 |\n| Stock - Single Material | TOPIC-006, TOPIC-021 |\n| Subcontracting Cockpit | TOPIC-032 |\n| Supplier Evaluation by Price | TOPIC-012 |\n| Supplier Evaluation by Time | TOPIC-012, TOPIC-048 |\n| Supplier Invoices List | TOPIC-028, TOPIC-047 |\n| Transfer Stock - Cross-Plant | TOPIC-025 |\n| Transfer Stock - In-Plant | TOPIC-025 |",
   "parent": "Wiki"
  },
  {
   "title": "Module_Index",
   "text": "# Module index\n\n## Module 01 - Foundation (V01 - SAP Foundation)\n\n### TOPIC-001 ERP, SAP and the Role of MM\n\nTopics: What is ERP; What is SAP; SAP ECC vs SAP S/4HANA; SAP modules overview; SAP MM role in an organization; Master data; Transactional data; Configuration vs master data; Customizing vs transaction processing; SAP terminology\n\n- THY-001 ERP, SAP and the SAP modules (Theory, 3 h)\n- THY-002 Master data, transactional data, configuration and customizing (Theory, 2 h)\n\n### TOPIC-002 Procurement and Inventory Lifecycles\n\nTopics: Procure-to-Pay; Source-to-Pay; Purchase-to-Pay; Inventory lifecycle; Material lifecycle; Supplier lifecycle; Procurement lifecycle\n\n- THY-003 Procure-to-Pay, Source-to-Pay and Purchase-to-Pay (Theory, 3 h)\n- THY-004 Material, supplier, inventory and procurement lifecycles (Theory, 2 h)\n\n### TOPIC-003 Procurement Business Basics\n\nTopics: Purchase requisition; Request for quotation; Quotation; Vendor/supplier; Purchase order; Goods receipt; Invoice; Payment; Purchase return; Credit memo; Debit memo; Contract; Scheduling agreement; Source determination\n\n- THY-005 Procurement documents and why each exists (Theory, 3 h)\n- EX-001 Read real procurement documents (Practical Exercise, 2 h)\n\n### TOPIC-004 Inventory Business Basics\n\nTopics: Stock; Unrestricted stock; Quality inspection stock; Blocked stock; Plant stock; Storage location stock; Batch stock; Special stock; Consignment stock; Stock transfer; Goods receipt; Goods issue; Transfer posting; Physical inventory\n\n- THY-006 Stock, stock types and stock levels (Theory, 3 h)\n- EX-002 Stock card exercise (Practical Exercise, 2 h)\n\n### TOPIC-005 Accounting Basics for MM\n\nTopics: Asset; Liability; Expense; Revenue; Inventory value; GR/IR; Accounts payable; General ledger; Cost center; Profit center; Purchase price; Material valuation; Consumption posting; Why MM transactions create FI accounting documents\n\n- THY-007 Accounts, debit and credit for procurement people (Theory, 3 h)\n- THY-008 Why MM transactions create accounting documents (Theory, 2 h)\n- EX-003 Journal entries for a purchase cycle (Practical Exercise, 3 h)\n\n### TOPIC-006 SAP Navigation: GUI and Fiori\n\nTopics: SAP GUI; SAP Fiori; SAP navigation; Easy Access menu; Transaction codes; Sessions; Favourites; Help; Document display\n\n- EX-004 Access the training system (Practical Exercise, 2 h)\n- EX-005 SAP GUI and Fiori navigation for materials management (Practical Exercise, 3 h)\n- MM-LAB-001 Complete Procure-to-Pay (Business Process Lab, 4 h)\n\n### TOPIC-007 MM Document Flow\n\nTopics: Purchase requisition; RFQ; Quotation; Purchase order; Goods receipt; Material document; Accounting document; Invoice receipt; Supplier payment; For each document: what is generated, why, which module owns it, what data changes, what accounting impact occurs, how to troubleshoot it\n\n- THY-009 The MM document flow (Theory, 2 h)\n- EX-006 Document-flow exercise 1: trace the first purchase (Practical Exercise, 2 h)\n- ASM-001 Foundation assessment: SAP basics, procurement basics and accounting basics (Assessment, 3 h)\n\n## Module 02 - Organizational Structure (V02 - MM Core)\n\n### TOPIC-008 SAP MM Organizational Structure\n\nTopics: Client; Company; Company code; Plant; Storage location; Purchasing organization; Purchasing group; Valuation area; Assignment relationships; Organizational models\n\n- THY-010 Organizational units and their meaning (Theory, 3 h)\n- THY-011 Organizational models for purchasing (Theory, 2 h)\n- MM-LAB-002 Create company, company code and plant (Configuration Lab, 3 h)\n- MM-LAB-003 Create storage locations (Configuration Lab, 2 h)\n- MM-LAB-004 Create purchasing organization and purchasing groups (Configuration Lab, 3 h)\n- MM-LAB-005 Make the plant ready for materials management (Configuration Lab, 2 h)\n- INC-001 Incident 01: Plant cannot be selected in purchasing (Troubleshooting Incident, 1 h)\n- ASM-002 Organizational structure assessment (Assessment, 2 h)\n\n## Module 03 - Material Master (V02 - MM Core)\n\n### TOPIC-009 Material Master Concepts and Configuration\n\nTopics: Material master concept; Material types; Material groups; Number ranges; Industry sector; Field selection; Material status; Internal numbering; External numbering\n\n- THY-012 The material master: one record, many views (Theory, 3 h)\n- THY-013 Views and organizational levels of the material (Theory, 3 h)\n- MM-LAB-006 Configure material types, number ranges and material groups (Configuration Lab, 3 h)\n- MM-LAB-007 Field selection and material status (Configuration Lab, 2 h)\n\n### TOPIC-010 Material Master Labs\n\nTopics: Raw materials; Semi-finished materials; Finished products; Trading goods; Consumables; Services; Purchasing data; MRP data; Accounting data; Storage data; Sales-related views; Batch management; Serial number concepts\n\n- MM-LAB-008 Create a raw material (Business Process Lab, 2 h)\n- MM-LAB-009 Create a finished product and a semi-finished material (Business Process Lab, 2 h)\n- MM-LAB-010 Create a trading material (Business Process Lab, 2 h)\n- MM-LAB-011 Create a consumable material (Business Process Lab, 2 h)\n- MM-LAB-012 Create a batch-managed material (Business Process Lab, 2 h)\n- EX-007 Extend, change, flag for deletion and list materials (Practical Exercise, 2 h)\n- INC-002 Incident 02: Material cannot be ordered: view or plant missing (Troubleshooting Incident, 1 h)\n- INC-003 Incident 03: Wrong unit of measure conversion in a purchase order (Troubleshooting Incident, 1 h)\n- ASM-003 Material master assessment (Assessment, 2 h)\n\n## Module 04 - Business Partner / Supplier (V02 - MM Core)\n\n### TOPIC-011 Business Partner and Supplier Master\n\nTopics: Business Partner; Supplier role; General data; Company code data; Purchasing organization data; Payment terms; Incoterms; Partner functions; Reconciliation account; Account group concepts; Number ranges; ECC vendor master vs S/4HANA Business Partner\n\n- THY-014 The business partner model and supplier data levels (Theory, 3 h)\n- MM-LAB-013 Business partner groupings, number ranges and account groups (Configuration Lab, 2 h)\n- MM-LAB-014 Create a supplier as business partner (Business Process Lab, 3 h)\n- MM-LAB-015 Partner functions and a foreign supplier (Business Process Lab, 2 h)\n\n### TOPIC-012 Supplier Classification, Blocking and Evaluation\n\nTopics: Supplier classification; Supplier blocking; Supplier evaluation concepts\n\n- THY-015 Supplier blocking, classification and evaluation (Theory, 2 h)\n- MM-LAB-016 Block a supplier and evaluate suppliers (Business Process Lab, 2 h)\n- INC-004 Incident 04: Supplier not available in the purchase order (Troubleshooting Incident, 1 h)\n- INC-005 Incident 05: Supplier exists but invoice cannot be posted (Troubleshooting Incident, 1 h)\n- ASM-004 Supplier master assessment (Assessment, 2 h)\n\n## Module 05 - Source Determination (V03 - Procurement)\n\n### TOPIC-013 Source Determination\n\nTopics: Source determination; Source list; Quota arrangement; Purchasing info record; Supplier-material relationship; Conditions; Source of supply; Fixed source; Automatic source determination\n\n- THY-016 Sources of supply and the order of determination (Theory, 3 h)\n- MM-LAB-017 Scenario: one material, one supplier (Business Process Lab, 2 h)\n- MM-LAB-018 Scenario: one material, multiple suppliers and a preferred supplier (Business Process Lab, 3 h)\n- MM-LAB-019 Scenario: quota-based sourcing (Business Process Lab, 3 h)\n- INC-006 Incident 06: Source not determined automatically in the requisition (Troubleshooting Incident, 1 h)\n- ASM-005 Source determination assessment (Assessment, 2 h)\n\n## Module 06 - Purchase Requisition (V03 - Procurement)\n\n### TOPIC-014 Purchase Requisition\n\nTopics: Purchase requisition; PR creation; Manual PR; MRP-generated PR; Account assignment; Material group; Delivery date; Quantity; Valuation; Release strategy/workflow concepts; Approval processes\n\n- THY-017 The purchase requisition (Theory, 2 h)\n- MM-LAB-020 Create requisitions for stock and for consumption (Business Process Lab, 3 h)\n- MM-LAB-021 PR to approval to PO (Business Process Lab, 3 h)\n- EX-008 Lists and collective processing of requisitions (Practical Exercise, 2 h)\n- INC-007 Incident 07: Requisition cannot be converted to a purchase order (Troubleshooting Incident, 1 h)\n- ASM-006 Purchase requisition assessment (Assessment, 1 h)\n\n## Module 07 - RFQ (V03 - Procurement)\n\n### TOPIC-015 Request for Quotation and Quotation\n\nTopics: RFQ; Supplier quotation; Price comparison; Quotation maintenance; Vendor selection; Source determination; Process: requirement, RFQ, supplier quotation, price comparison, supplier selection, purchase order\n\n- THY-018 The request for quotation process (Theory, 2 h)\n- MM-LAB-022 RFQ to quotation to price comparison (Business Process Lab, 4 h)\n- MM-LAB-023 Supplier selection to purchase order (Business Process Lab, 2 h)\n- ASG-001 Assignment: sourcing recommendation (Assignment, 2 h)\n- ASM-007 RFQ assessment (Assessment, 1 h)\n\n## Module 08 - Purchase Orders (V03 - Procurement)\n\n### TOPIC-016 Purchase Order Structure\n\nTopics: PO structure; Header; Item; Schedule lines; Account assignment; Delivery; Invoice; Conditions; Texts; Attachments; Output; Partner functions; Confirmation control\n\n- THY-019 Anatomy of a purchase order (Theory, 3 h)\n- MM-LAB-024 Standard purchase order for stock material (Business Process Lab, 3 h)\n- MM-LAB-025 Change, block, delete and monitor purchase orders (Business Process Lab, 2 h)\n\n### TOPIC-017 Purchase Order Types and Categories\n\nTopics: Standard PO; Stock PO; Consumable PO; Service PO; Subcontracting PO; Consignment PO; Third-party concepts; Framework orders; Item categories; Account assignment categories; Document types; Number ranges; Field selection; Tolerance concepts\n\n- THY-020 Item categories and account assignment categories (Theory, 3 h)\n- MM-LAB-026 Consumable purchase orders with account assignment (Business Process Lab, 3 h)\n- MM-LAB-027 Framework order and limit item (Business Process Lab, 2 h)\n- EX-009 Overview of special order types (Practical Exercise, 1 h)\n- INC-008 Incident 08: PO cannot be created: several causes (Troubleshooting Incident, 1 h)\n- INC-009 Incident 09: Duplicate purchase order for the same requisition (Troubleshooting Incident, 1 h)\n- ASM-008 Purchase order assessment (Assessment, 2 h)\n\n## Module 09 - Purchasing Configuration (V03 - Procurement)\n\n### TOPIC-018 Purchasing Configuration\n\nTopics: Purchasing document types; Number ranges; Item categories; Account assignment categories; Purchasing groups; Purchasing organizations; Release procedures/workflows; Output management; Partner determination; Confirmation control; Delivery tolerances; Invoice tolerances; Business Requirement to Configuration to Testing\n\n- THY-021 Reading purchasing customizing (Theory, 2 h)\n- MM-LAB-028 Document types and number ranges (Configuration Lab, 3 h)\n- MM-LAB-029 Account assignment categories and field selection (Configuration Lab, 3 h)\n- MM-LAB-030 Partner determination (Configuration Lab, 2 h)\n- MM-LAB-031 Output management for purchase orders (Configuration Lab, 3 h)\n- MM-LAB-032 Confirmation control (Configuration Lab, 2 h)\n- MM-LAB-033 Delivery tolerances and invoice tolerances (Configuration Lab, 3 h)\n- ASG-002 Assignment: requirement to configuration to test (Assignment, 2 h)\n- ASM-009 Purchasing configuration assessment (Assessment, 2 h)\n\n## Module 10 - Pricing & Conditions (V03 - Procurement)\n\n### TOPIC-019 Purchasing Pricing and Conditions\n\nTopics: Condition technique; Condition types; Access sequence; Condition tables; Calculation schema; Schema determination; Gross price; Discounts; Freight; Taxes; Planned delivery costs; Effective price; Net price; Statistical conditions; Master data vs condition records vs purchasing conditions vs schema\n\n- THY-022 The condition technique in purchasing (Theory, 3 h)\n- THY-023 Master data, condition records, purchasing conditions and schema (Theory, 2 h)\n- MM-LAB-034 Maintain conditions and read the price analysis (Business Process Lab, 3 h)\n- MM-LAB-035 Configure a condition type, access sequence and calculation schema (Configuration Lab, 4 h)\n- MM-LAB-036 Planned delivery costs and statistical conditions (Configuration Lab, 2 h)\n- INC-010 Incident 10: Wrong price in PO (Troubleshooting Incident, 1 h)\n- INC-011 Incident 11: Freight condition not found or not posted (Troubleshooting Incident, 1 h)\n- ASM-010 Pricing assessment (Assessment, 2 h)\n\n## Module 11 - Release / Workflow (V03 - Procurement)\n\n### TOPIC-020 Release Strategy and Approval Workflow\n\nTopics: Purchase requisition approval; Purchase order approval; Release procedures; Classification concepts; Workflow concepts; Flexible workflow in S/4HANA; Approval hierarchy; Approval thresholds; Role-based approval\n\n- THY-024 Approval concepts: release procedure and flexible workflow (Theory, 3 h)\n- MM-LAB-037 Release strategy for purchase orders with three thresholds (Configuration Lab, 4 h)\n- MM-LAB-038 Release for purchase requisitions (Configuration Lab, 3 h)\n- MM-LAB-039 Flexible workflow in S/4HANA (Configuration Lab, 3 h)\n- ASG-003 Assignment: approval matrix (Assignment, 2 h)\n- INC-012 Incident 12: PO approval pending: release strategy not triggered (Troubleshooting Incident, 1 h)\n- INC-013 Incident 13: Workflow not triggered or approver receives nothing (Troubleshooting Incident, 1 h)\n- ASM-011 Release and workflow assessment (Assessment, 2 h)\n\n## Module 12 - Inventory Management (V04 - Inventory)\n\n### TOPIC-021 Inventory Management Fundamentals\n\nTopics: Goods receipt; Goods issue; Transfer posting; Stock transfer; Reservations; Material documents; Accounting documents; Stock types; Stock overview; Batch stock; Serial numbers; Special stock\n\n- THY-025 Goods movements and the documents they create (Theory, 3 h)\n- EX-010 The goods movement transaction and stock reports (Practical Exercise, 3 h)\n- MM-LAB-040 Reservations (Business Process Lab, 2 h)\n\n### TOPIC-022 Movement Types\n\nTopics: Movement types for goods receipt, goods issue, transfer posting, stock transfer, return to vendor, scrapping, sampling, initial stock and physical inventory adjustments; For each: business meaning, quantity impact, stock impact, accounting impact, FI integration, reversal, real-world use case\n\n- THY-026 What a movement type controls (Theory, 3 h)\n- EX-011 Movement type reference sheet part 1: receipts, returns and initial stock (Practical Exercise, 3 h)\n- EX-012 Movement type reference sheet part 2: issues, scrapping and sampling (Practical Exercise, 3 h)\n- EX-013 Movement type reference sheet part 3: transfers, stock type changes and inventory differences (Practical Exercise, 3 h)\n- MM-LAB-041 Copy and adjust a movement type (Configuration Lab, 2 h)\n- INC-014 Incident 14: GR cannot be posted: movement type not allowed or field missing (Troubleshooting Incident, 1 h)\n- ASM-012 Inventory management assessment (Assessment, 2 h)\n\n## Module 13 - Goods Receipt (V04 - Inventory)\n\n### TOPIC-023 Goods Receipt\n\nTopics: GR against PO; GR without PO; Partial GR; Over-delivery; Under-delivery; Tolerance; GR reversal; Returns; Batch-managed GR; Serial-number GR; Flow: purchase order, goods receipt, material document, accounting document, stock updated\n\n- THY-027 Goods receipt and its effects (Theory, 2 h)\n- MM-LAB-042 GR against PO: full and partial (Business Process Lab, 3 h)\n- MM-LAB-043 Over-delivery, under-delivery and tolerances (Business Process Lab, 2 h)\n- MM-LAB-044 GR reversal and return to supplier (Business Process Lab, 3 h)\n- MM-LAB-045 GR without PO, batch-managed and serial-number GR (Business Process Lab, 3 h)\n- MM-LAB-046 GR into blocked stock and release (Business Process Lab, 2 h)\n- INC-015 Incident 15: GR cannot be posted: posting period, tolerance or missing data (Troubleshooting Incident, 1 h)\n- INC-016 Incident 16: GR quantity mismatch between delivery note and system (Troubleshooting Incident, 1 h)\n- ASM-013 Goods receipt assessment (Assessment, 2 h)\n\n## Module 14 - Goods Issue (V04 - Inventory)\n\n### TOPIC-024 Goods Issue\n\nTopics: Goods issue; Consumption; Cost center consumption; Production consumption; Scrapping; Sales-related concepts; Reservation-based GI; GI reversal; Integration with FI, CO, PP and SD\n\n- THY-028 Goods issue and consumption (Theory, 2 h)\n- MM-LAB-047 Goods issue to a cost centre and with reference to a reservation (Business Process Lab, 3 h)\n- MM-LAB-048 Goods issue to a production order and scrapping (Business Process Lab, 3 h)\n- EX-014 Goods issue for sales: concept walkthrough (Practical Exercise, 1 h)\n- INC-017 Incident 17: Goods issue fails: stock deficit (Troubleshooting Incident, 1 h)\n- INC-018 Incident 18: Goods issue posts to the wrong account (Troubleshooting Incident, 1 h)\n- ASM-014 Goods issue assessment (Assessment, 2 h)\n\n## Module 15 - Stock Transfer (V04 - Inventory)\n\n### TOPIC-025 Transfer Postings and Stock Transfers\n\nTopics: Storage location transfer; Plant-to-plant transfer; One-step transfer; Two-step transfer; Transfer posting between stock types and materials\n\n- THY-029 Transfer posting versus stock transfer (Theory, 2 h)\n- MM-LAB-049 Storage location and stock type transfers (Business Process Lab, 2 h)\n- MM-LAB-050 Plant-to-plant transfer in one and two steps (Business Process Lab, 3 h)\n\n### TOPIC-026 Stock Transport Orders\n\nTopics: Stock transport order; Intracompany STO; Intercompany STO; Delivery-based STO concepts; Transportation considerations\n\n- THY-030 Stock transport orders (Theory, 3 h)\n- MM-LAB-051 Intracompany STO without delivery (Business Process Lab, 3 h)\n- MM-LAB-052 Configure delivery-based STO (Configuration Lab, 3 h)\n- MM-LAB-053 Delivery-based STO (Business Process Lab, 3 h)\n- EX-015 Intercompany STO: process walkthrough (Practical Exercise, 2 h)\n- INC-019 Incident 19: STO not working: delivery cannot be created (Troubleshooting Incident, 1 h)\n- INC-020 Incident 20: STO failure: goods receipt not possible or stock stuck in transit (Troubleshooting Incident, 1 h)\n- ASM-015 Stock transfer assessment (Assessment, 2 h)\n\n## Module 16 - Physical Inventory (V04 - Inventory)\n\n### TOPIC-027 Physical Inventory\n\nTopics: Physical inventory process; Inventory document; Counting; Recount; Difference posting; Inventory adjustments; Cycle counting; Periodic inventory; Continuous inventory; Inventory accuracy\n\n- THY-031 Physical inventory methods and process (Theory, 2 h)\n- MM-LAB-054 Physical inventory end to end (Business Process Lab, 4 h)\n- MM-LAB-055 Cycle counting and inventory tolerances (Configuration Lab, 3 h)\n- EX-016 Batch creation of inventory documents and inventory accuracy (Practical Exercise, 2 h)\n- INC-021 Incident 21: Physical inventory difference cannot be posted (Troubleshooting Incident, 1 h)\n- INC-022 Incident 22: Stock mismatch between system and warehouse (Troubleshooting Incident, 1 h)\n- ASM-016 Physical inventory assessment (Assessment, 2 h)\n\n## Module 17 - Invoice Verification (V06 - Invoice Verification)\n\n### TOPIC-028 Logistics Invoice Verification\n\nTopics: Invoice verification; Three-way matching; PO; GR; Invoice; GR/IR; Invoice blocking; Price variance; Quantity variance; Tax; Planned delivery costs; Credit memo; Subsequent debit; Subsequent credit; Invoice reversal\n\n- THY-032 Invoice verification and the three-way match (Theory, 3 h)\n- MM-LAB-056 Post an invoice with a clean three-way match (Business Process Lab, 3 h)\n- MM-LAB-057 Price variance and quantity variance (Business Process Lab, 4 h)\n- MM-LAB-058 Planned and unplanned delivery costs and tax (Business Process Lab, 3 h)\n- MM-LAB-059 Credit memo, subsequent debit and subsequent credit (Business Process Lab, 3 h)\n- MM-LAB-060 Park, block, release and reverse invoices (Business Process Lab, 3 h)\n- MM-LAB-061 Invoice verification configuration: tolerances, blocks and tax defaults (Configuration Lab, 3 h)\n- INC-023 Incident 23: Invoice blocked for payment (Troubleshooting Incident, 1 h)\n- INC-024 Incident 24: Duplicate invoice accepted or wrongly refused (Troubleshooting Incident, 1 h)\n- INC-025 Incident 25: GR/IR mismatch on a purchase order (Troubleshooting Incident, 1 h)\n- ASM-017 Invoice verification assessment (Assessment, 2 h)\n\n## Module 18 - Account Determination (V05 - Valuation)\n\n### TOPIC-029 Automatic Account Determination\n\nTopics: Valuation; Valuation area; Valuation class; Account category reference; Transaction keys; Automatic account determination; Inventory account; GR/IR; Consumption account; Price difference; Stock posting; Chain: material, valuation class, transaction, account determination, G/L\n\n- THY-033 From material to general ledger account (Theory, 4 h)\n- EX-017 Read account determination with the simulation (Practical Exercise, 3 h)\n- MM-LAB-062 Configure valuation classes and account determination for a new material type (Configuration Lab, 4 h)\n- MM-LAB-063 Scenario set: account determination for six business cases (Business Process Lab, 4 h)\n- INC-026 Incident 26: Wrong account posting from a goods movement (Troubleshooting Incident, 1 h)\n- INC-027 Incident 27: Account determination error at goods receipt (Troubleshooting Incident, 1 h)\n- INC-028 Incident 28: Wrong valuation class in the material (Troubleshooting Incident, 1 h)\n- ASM-018 Account determination assessment (Assessment, 2 h)\n\n## Module 19 - Material Valuation (V05 - Valuation)\n\n### TOPIC-030 Material Valuation\n\nTopics: Standard price; Moving average price; Price control; Material valuation; Split valuation; Valuation categories; Valuation types; Price differences; Accounting impact\n\n- THY-034 Price control: standard and moving average (Theory, 3 h)\n- MM-LAB-064 Valuation with moving average and standard price (Business Process Lab, 4 h)\n- MM-LAB-065 Price change and revaluation (Business Process Lab, 2 h)\n- MM-LAB-066 Split valuation (Configuration Lab, 3 h)\n- INC-029 Incident 29: Stock value differs from the general ledger (Troubleshooting Incident, 1 h)\n- INC-030 Incident 30: Unexpected price difference posting at invoice (Troubleshooting Incident, 1 h)\n- ASM-019 Valuation assessment (Assessment, 2 h)\n\n## Module 20 - Material Ledger (V05 - Valuation)\n\n### TOPIC-031 Material Ledger and Actual Costing\n\nTopics: Material Ledger; Purpose; Inventory valuation; Multiple currencies; Multiple valuations; Actual costing; Period-end processing; Price determination; S/4HANA Material Ledger requirements\n\n- THY-035 The Material Ledger in S/4HANA (Theory, 3 h)\n- THY-036 Actual costing concepts (Theory, 3 h)\n- EX-018 Material price analysis (Practical Exercise, 2 h)\n- EX-019 Period-end processing for materials: walkthrough (Practical Exercise, 2 h)\n- ASM-020 Material Ledger assessment (Assessment, 1 h)\n\n## Module 21 - Special Procurement (V07 - Special Procurement)\n\n### TOPIC-032 Subcontracting\n\nTopics: Flow: company material, components sent to supplier, supplier processing, finished material received; BOM/components; Subcontracting PO; Component consumption; GR; Automatic consumption; Variances\n\n- THY-037 Subcontracting (Theory, 2 h)\n- MM-LAB-067 Subcontracting end to end (Business Process Lab, 5 h)\n- INC-031 Incident 31: Subcontracting component missing at goods receipt (Troubleshooting Incident, 1 h)\n\n### TOPIC-033 Consignment and Pipeline\n\nTopics: Consignment stock; Consignment settlement; Consumption; Liability; Ownership; Pipeline procurement concepts\n\n- THY-038 Supplier consignment and pipeline (Theory, 2 h)\n- MM-LAB-068 Consignment end to end (Business Process Lab, 4 h)\n- INC-032 Incident 32: Consignment stock issue: settlement shows nothing or wrong price (Troubleshooting Incident, 1 h)\n\n### TOPIC-034 Third-Party and Stock Transfer Procurement\n\nTopics: Third-party procurement; Integration with SD; Stock transfer procurement by special procurement key\n\n- THY-039 Third-party procurement and special procurement keys (Theory, 2 h)\n- MM-LAB-069 Third-party procurement from the purchasing side (Business Process Lab, 3 h)\n- ASM-021 Special procurement assessment (Assessment, 2 h)\n\n## Module 22 - Service Procurement (V07 - Special Procurement)\n\n### TOPIC-035 Service Procurement\n\nTopics: Service master concepts; Service PO; Service entry sheet; Acceptance; Invoice; Account assignment; Service procurement lifecycle: requirement, service PO, service entry, approval, invoice, payment\n\n- THY-040 Service procurement in ECC and S/4HANA (Theory, 3 h)\n- MM-LAB-070 Service order to service entry to invoice (Business Process Lab, 4 h)\n- INC-033 Incident 33: Service entry sheet cannot be accepted or invoiced (Troubleshooting Incident, 1 h)\n- ASM-022 Service procurement assessment (Assessment, 1 h)\n\n## Module 23 - Contracts (V07 - Special Procurement)\n\n### TOPIC-036 Contracts and Scheduling Agreements\n\nTopics: Quantity contracts; Value contracts; Scheduling agreements; Release documentation; Schedule lines; Supplier commitments; Long-term procurement\n\n- THY-041 Outline agreements (Theory, 2 h)\n- MM-LAB-071 Business case: quantity contract with release orders (Business Process Lab, 3 h)\n- MM-LAB-072 Business case: value contract (Business Process Lab, 2 h)\n- MM-LAB-073 Business case: scheduling agreement with delivery schedule (Business Process Lab, 3 h)\n- INC-034 Incident 34: Contract not proposed as source or cannot be released against (Troubleshooting Incident, 1 h)\n- ASM-023 Contracts assessment (Assessment, 1 h)\n\n## Module 24 - MRP Integration (V08 - Integration)\n\n### TOPIC-037 MRP and Procurement\n\nTopics: MRP fundamentals; Material requirements; MRP controller; MRP types; Lot sizing; Reorder point; Safety stock; Planned orders; Purchase requisitions; External procurement; Internal procurement; MRP-generated procurement proposals; Flow: demand, MRP, procurement proposal, PR, PO, GR\n\n- THY-042 MRP fundamentals for the MM consultant (Theory, 3 h)\n- MM-LAB-074 Reorder point planning to purchase order (Business Process Lab, 3 h)\n- MM-LAB-075 Demand-driven planning with lot sizes and safety stock (Business Process Lab, 3 h)\n- INC-035 Incident 35: MRP not generating PR (Troubleshooting Incident, 1 h)\n- INC-036 Incident 36: Incorrect delivery date in MRP proposals (Troubleshooting Incident, 1 h)\n- ASM-024 MRP integration assessment (Assessment, 2 h)\n\n## Module 25 - MM-FI Integration (V08 - Integration)\n\n### TOPIC-038 MM-FI Integration\n\nTopics: GR accounting; Invoice accounting; GR/IR; Inventory; Consumption; Tax; Supplier liability; Account determination\n\n- THY-043 Where MM meets FI (Theory, 2 h)\n- MM-LAB-076 Follow one purchase through FI to payment (Business Process Lab, 3 h)\n- MM-LAB-077 GR/IR account analysis and maintenance (Business Process Lab, 3 h)\n- INC-037 Incident 37: Tax issue: wrong or missing tax in the supplier invoice (Troubleshooting Incident, 1 h)\n- ASM-025 MM-FI integration assessment (Assessment, 1 h)\n\n## Module 26 - MM-CO Integration (V08 - Integration)\n\n### TOPIC-039 MM-CO Integration\n\nTopics: Cost center; Internal order; Profit center; Consumption; Cost allocation\n\n- THY-044 Cost objects in procurement and inventory (Theory, 2 h)\n- MM-LAB-078 Costs and commitments from purchasing (Business Process Lab, 3 h)\n- ASM-026 MM-CO integration assessment (Assessment, 1 h)\n\n## Module 27 - MM-SD Integration (V08 - Integration)\n\n### TOPIC-040 MM-SD Integration\n\nTopics: Third-party procurement; Stock availability; Sales-related procurement; Delivery/inventory integration\n\n- THY-045 Where MM meets SD (Theory, 2 h)\n- MM-LAB-079 Stock, availability and the sales goods issue (Business Process Lab, 3 h)\n- ASM-027 MM-SD integration assessment (Assessment, 1 h)\n\n## Module 28 - MM-PP Integration (V08 - Integration)\n\n### TOPIC-041 MM-PP Integration\n\nTopics: BOM; MRP; Production order; Component consumption; Goods receipt; Production planning\n\n- THY-046 Where MM meets PP (Theory, 2 h)\n- MM-LAB-080 Components to production and finished goods back (Business Process Lab, 3 h)\n- ASM-028 MM-PP integration assessment (Assessment, 1 h)\n\n## Module 29 - MM-QM Integration (V08 - Integration)\n\n### TOPIC-042 MM-QM Integration\n\nTopics: Quality inspection; Inspection stock; Usage decision; Supplier quality concepts\n\n- THY-047 Where MM meets QM (Theory, 2 h)\n- MM-LAB-081 Goods receipt with inspection lot and usage decision (Business Process Lab, 3 h)\n- ASM-029 MM-QM integration assessment (Assessment, 1 h)\n\n## Module 30 - MM-WM/EWM Integration (V08 - Integration)\n\n### TOPIC-043 MM-WM/EWM Integration\n\nTopics: Warehouse integration; Putaway; Picking; Stock movements; Warehouse management concepts; EWM integration\n\n- THY-048 Inventory management versus warehouse management (Theory, 3 h)\n- EX-020 Inbound with warehouse management: guided walkthrough (Practical Exercise, 3 h)\n- ASM-030 MM-WM/EWM integration assessment (Assessment, 1 h)\n\n## Module 31 - S/4HANA Procurement (V09 - S/4HANA)\n\n### TOPIC-044 SAP S/4HANA Procurement\n\nTopics: SAP S/4HANA architecture; SAP Fiori; Business Partner; Supplier management; Simplification items; Procurement innovations; Embedded analytics; Workflow; Flexible workflow; APIs; CDS concepts; Extensibility concepts; ECC MM vs S/4HANA Procurement\n\n- THY-049 S/4HANA architecture and the MM simplifications (Theory, 4 h)\n- THY-050 Procurement innovations, APIs, CDS and extensibility (Theory, 3 h)\n- EX-021 Data model: where stock and documents live in S/4HANA (Practical Exercise, 2 h)\n\n### TOPIC-045 Source-to-Pay\n\nTopics: Supplier discovery; Supplier qualification; Sourcing; RFQ; Quotation; Supplier selection; Contract; Purchase requisition; Purchase order; Goods receipt; Invoice; Payment; Supplier evaluation; Where SAP MM participates in every stage\n\n- THY-051 Source-to-Pay and the place of MM (Theory, 2 h)\n- ASG-004 Assignment: map the course company to Source-to-Pay (Assignment, 2 h)\n- ASM-031 S/4HANA procurement assessment (Assessment, 2 h)\n\n## Module 32 - Fiori (V09 - S/4HANA)\n\n### TOPIC-046 S/4HANA Fiori Procurement\n\nTopics: Fiori launchpad; Business roles; Procurement apps; Purchase requisition apps; Purchase order apps; Supplier apps; Goods movement apps; Invoice apps; Approval apps; Analytical apps; Classic SAP GUI approach vs S/4HANA Fiori approach for every process\n\n- THY-052 Fiori app types, business roles and the apps reference library (Theory, 2 h)\n- MM-LAB-082 Fiori exercise: purchaser (Business Process Lab, 3 h)\n- MM-LAB-083 Fiori exercise: warehouse clerk and inventory manager (Business Process Lab, 3 h)\n- MM-LAB-084 Fiori exercise: accounts payable (Business Process Lab, 2 h)\n- ASG-005 Assignment: GUI versus Fiori table (Assignment, 2 h)\n- ASM-032 Fiori assessment (Assessment, 1 h)\n\n## Module 33 - Analytics (V09 - S/4HANA)\n\n### TOPIC-047 SAP MM Reporting\n\nTopics: Reporting for purchasing, purchase requisitions, purchase orders, goods movements, stock, inventory valuation, supplier analysis, invoice verification, material consumption; CDS views; Embedded analytics; Fiori analytical apps; Query/reporting concepts\n\n- MM-LAB-085 Purchasing reports (Business Process Lab, 3 h)\n- MM-LAB-086 Inventory, valuation, consumption and invoice reports (Business Process Lab, 3 h)\n- THY-053 CDS views, embedded analytics and query concepts (Theory, 2 h)\n\n### TOPIC-048 Procurement Analytics\n\nTopics: Procurement KPIs; Spend analysis; Supplier performance; Purchase order analysis; Delivery performance; Price variance; Purchase requisition aging; GR/IR aging; Inventory turnover; Stock value; Slow-moving inventory; Overstock; Stock-out; Procurement cycle time\n\n- THY-054 Procurement and inventory key figures (Theory, 2 h)\n- MM-LAB-087 Build the procurement dashboard (Business Process Lab, 4 h)\n- MM-LAB-088 Build the inventory dashboard (Business Process Lab, 3 h)\n- ASM-033 Analytics assessment (Assessment, 1 h)\n\n## Module 34 - Security (V09 - S/4HANA)\n\n### TOPIC-049 MM Security and Authorization\n\nTopics: Roles; Authorization objects; Organizational restrictions; Purchasing organization restrictions; Plant restrictions; Storage location restrictions; Approval authorization; Segregation of duties; Procurement fraud risks; Collaboration with SAP Security/Basis teams\n\n- THY-055 Functional security for MM (Theory, 3 h)\n- THY-056 Segregation of duties and procurement fraud risks (Theory, 2 h)\n- EX-022 Authorization failure analysis and role requirement (Practical Exercise, 2 h)\n- ASG-006 Assignment: segregation of duties matrix (Assignment, 2 h)\n- ASM-034 Security assessment (Assessment, 1 h)\n\n## Module 35 - Testing (V10 - Testing & Migration)\n\n### TOPIC-050 SAP MM Testing\n\nTopics: Unit testing; Integration testing; Regression testing; User acceptance testing; Performance testing concepts; Negative testing; Authorization testing; Test case content: test ID, requirement, preconditions, test steps, expected result, actual result, status, defect ID, evidence\n\n- THY-057 Test levels and the test case standard (Theory, 2 h)\n- EX-023 Test cases: PR, RFQ and PO (Practical Exercise, 4 h)\n- EX-024 Test cases: GR, GI, STO and returns (Practical Exercise, 4 h)\n- EX-025 Test cases: invoice, subcontracting, consignment and service procurement (Practical Exercise, 4 h)\n- EX-026 Negative and authorization tests (Practical Exercise, 3 h)\n- EX-027 Integration test, regression pack and user acceptance plan (Practical Exercise, 3 h)\n- DEF-001 Defect: record, analyse and retest three defects (Defect, 2 h)\n- ASM-035 Testing assessment (Assessment, 2 h)\n\n## Module 36 - Data Migration (V10 - Testing & Migration)\n\n### TOPIC-051 MM Data Migration\n\nTopics: Legacy system analysis; Data cleansing; Mapping; Material migration; Supplier migration; Purchasing data; Stock migration; Open PO migration; Open PR migration; Historical data concepts; Migration validation; Reconciliation; SAP Migration Cockpit; Migration objects; Templates; Staging concepts; Data validation; Cutover migration\n\n- THY-058 Migration objects, sequence and reconciliation (Theory, 3 h)\n- THY-059 The Migration Cockpit: objects, templates and staging (Theory, 2 h)\n- EX-028 Migration exercise 1: cleanse and map legacy data (Practical Exercise, 3 h)\n- MM-LAB-089 Migrate suppliers and materials (Business Process Lab, 4 h)\n- MM-LAB-090 Migrate purchasing data and open purchase orders (Business Process Lab, 3 h)\n- MM-LAB-091 Migrate stock (Business Process Lab, 3 h)\n- ASG-007 Assignment: migration strategy (Assignment, 3 h)\n- ASM-036 Migration assessment (Assessment, 2 h)\n\n## Module 37 - SAP Activate (V10 - Testing & Migration)\n\n### TOPIC-052 Implementation Methodology: SAP Activate\n\nTopics: Discover; Prepare; Explore; Realize; Deploy; Run; Business requirement gathering; Fit-to-standard; Gap analysis; Business process design; Configuration; Development coordination; Testing; Migration; Training; Cutover; Go-live; Hypercare\n\n- THY-060 SAP Activate and its phases (Theory, 3 h)\n- ASG-008 Assignment: fit-to-standard workshop and gap analysis for procurement (Assignment, 4 h)\n- ASG-009 Assignment: cutover plan and go-live checklist (Assignment, 3 h)\n\n### TOPIC-053 SAP MM Configuration Methodology\n\nTopics: Chain: business requirement, process design, configuration, master data, unit test, integration test, user acceptance test, documentation, transport, production; IMG/SPRO; Configuration documentation; Configuration rationale; Transport concepts; Naming conventions; Change management; Functional specifications; Test scripts; Configuration workbook\n\n- THY-061 From requirement to production (Theory, 3 h)\n- EX-029 IMG navigation and transport requests (Practical Exercise, 3 h)\n- DOC-001 Configuration workbook (Documentation, 4 h)\n\n### TOPIC-054 Functional Specifications\n\nTopics: FS structure: business requirement, functional requirement, current process, future process, input, processing logic, output, business rules, error handling, security, dependencies, acceptance criteria; Examples: custom procurement report, purchase order enhancement, approval enhancement, supplier report, inventory report, interface requirement\n\n- THY-062 How to write a functional specification (Theory, 2 h)\n- DOC-002 Functional specification: custom procurement report (Documentation, 3 h)\n- DOC-003 Functional specification: purchase order or approval enhancement (Documentation, 3 h)\n- DOC-004 Functional specification: interface requirement (Documentation, 3 h)\n- ASM-037 Implementation assessment (Assessment, 2 h)\n\n## Module 38 - Production Support (V11 - Production Support)\n\n### TOPIC-055 Production Support\n\nTopics: Incident management; Priority; Severity; SLA; Root cause analysis; Problem management; Change requests; Transport management; Emergency fixes; User communication; Documentation; Knowledge base\n\n- THY-063 Support processes: incident, problem and change (Theory, 3 h)\n- EX-030 Support tools for the MM consultant (Practical Exercise, 3 h)\n- PRD-001 Production incident 01: PO cannot be created (Production Incident, 1 h)\n- PRD-002 Production incident 02: Supplier not available (Production Incident, 1 h)\n- PRD-003 Production incident 03: Material cannot be ordered (Production Incident, 1 h)\n- PRD-004 Production incident 04: Wrong price in PO (Production Incident, 1 h)\n- PRD-005 Production incident 05: GR cannot be posted (Production Incident, 1 h)\n- PRD-006 Production incident 06: Invoice blocked (Production Incident, 1 h)\n- PRD-007 Production incident 07: Wrong account posting (Production Incident, 1 h)\n- PRD-008 Production incident 08: Stock mismatch (Production Incident, 1 h)\n- PRD-009 Production incident 09: MRP not generating PR (Production Incident, 1 h)\n- PRD-010 Production incident 10: STO not working (Production Incident, 1 h)\n- PRD-011 Production incident 11: Approval workflow failure (Production Incident, 1 h)\n- CR-001 Change request: new purchasing group and approval threshold (Change Request, 2 h)\n- CR-002 Change request: new movement type for sample issues (Change Request, 2 h)\n- CR-003 Emergency fix: invoices blocked by a wrong tolerance after a transport (Change Request, 2 h)\n- DOC-005 Root cause analysis and knowledge base article (Documentation, 3 h)\n- DOC-006 Production support runbook and issue log (Documentation, 3 h)\n- ASM-038 Production support assessment (Assessment, 2 h)\n\n## Module 39 - Troubleshooting (V11 - Production Support)\n\n### TOPIC-056 SAP MM Troubleshooting\n\nTopics: Framework: problem, business impact, reproduce, check master data, check configuration, check authorization, check integration, check documents, identify root cause, fix, test, document RCA\n\n- THY-064 The troubleshooting framework (Theory, 2 h)\n- INC-038 Incident 38: Supplier price changed but orders still use the old price (Troubleshooting Incident, 1 h)\n- INC-039 Incident 39: Material blocked for procurement in one plant only (Troubleshooting Incident, 1 h)\n- INC-040 Incident 40: Supplier blocked: order exists but goods receipt and invoice behave differently (Troubleshooting Incident, 1 h)\n- INC-041 Incident 41: Wrong purchasing organization proposed or used in the order (Troubleshooting Incident, 1 h)\n- INC-042 Incident 42: Incorrect plant or wrong storage location in a goods receipt (Troubleshooting Incident, 1 h)\n- INC-043 Incident 43: Partial delivery closed the order by mistake (Troubleshooting Incident, 1 h)\n- INC-044 Incident 44: Over-delivery accepted without warning (Troubleshooting Incident, 1 h)\n- INC-045 Incident 45: Under-delivery leaves an open commitment (Troubleshooting Incident, 1 h)\n- INC-046 Incident 46: Return to supplier does not reduce the invoice expectation (Troubleshooting Incident, 1 h)\n- INC-047 Incident 47: Batch not found or shelf life check fails at goods receipt (Troubleshooting Incident, 1 h)\n- INC-048 Incident 48: Output not sent to the supplier (Troubleshooting Incident, 1 h)\n- INC-049 Incident 49: Purchase order shows no tax code or the invoice proposes the wrong one (Troubleshooting Incident, 1 h)\n- INC-050 Incident 50: Requisition from planning has no source and is not converted (Troubleshooting Incident, 1 h)\n- INC-051 Incident 51: Config works in development but not in quality: transport missing (Troubleshooting Incident, 2 h)\n- INC-052 Incident 52: Reservation is not reduced by the goods issue (Troubleshooting Incident, 1 h)\n- INC-053 Incident 53: Goods receipt for an account-assigned order posts to an unexpected account (Troubleshooting Incident, 1 h)\n- INC-054 Incident 54: Posting to a previous period is not possible (Troubleshooting Incident, 1 h)\n- INC-055 Incident 55: Month-end multi-fault case in Procure-to-Pay (Troubleshooting Incident, 4 h)\n- ASM-039 Troubleshooting assessment (Assessment, 3 h)\n\n## Module 40 - Real-World Projects (V12 - Advanced Consulting)\n\n### TOPIC-057 Real-World Business Process Projects\n\nTopics: Standard procurement; Strategic procurement; Subcontracting; Consignment; Stock transport; Service procurement; MRP procurement; Physical inventory; Month-end procurement closing\n\n- PROJECT-001 Project 1 - Standard Procurement: PR, PO, GR, invoice, payment (Real-World Project, 5 h)\n- PROJECT-002 Project 2 - Strategic Procurement: requirement, RFQ, quotation, supplier selection, contract, PO, GR, invoice (Real-World Project, 6 h)\n- PROJECT-003 Project 3 - Subcontracting (Real-World Project, 5 h)\n- PROJECT-004 Project 4 - Consignment (Real-World Project, 4 h)\n- PROJECT-005 Project 5 - Stock Transport (Real-World Project, 4 h)\n- PROJECT-006 Project 6 - Service Procurement (Real-World Project, 4 h)\n- PROJECT-007 Project 7 - MRP Procurement (Real-World Project, 4 h)\n- PROJECT-008 Project 8 - Physical Inventory (Real-World Project, 4 h)\n- PROJECT-009 Project 9 - Month-End Procurement Closing (Real-World Project, 5 h)\n\n### TOPIC-058 Month-End and Year-End MM Activities\n\nTopics: Open PO review; GR/IR reconciliation; Invoice verification; Stock valuation; Physical inventory; Consumption review; Price differences; Material Ledger closing concepts; Outstanding procurement documents; Blocked invoices; Supplier reconciliation; Period-end activities\n\n- THY-065 What MM owes finance at period end (Theory, 2 h)\n- MM-LAB-092 Closing lab 1: open purchasing documents and blocked invoices (Business Process Lab, 3 h)\n- MM-LAB-093 Closing lab 2: GR/IR reconciliation and supplier reconciliation (Business Process Lab, 3 h)\n- MM-LAB-094 Closing lab 3: stock valuation, consumption and price differences (Business Process Lab, 3 h)\n- MM-LAB-095 Closing lab 4: period close and year-end activities (Business Process Lab, 2 h)\n\n### TOPIC-059 Real-World Scenario Bank\n\nTopics: One hundred business scenarios across master data, sourcing, purchasing, approval, inventory, invoice, valuation, special procurement, integration and support; the full list is on the Scenario_Bank wiki page\n\n- ASG-010 Scenario pack 01: scenarios 1-10 (Assignment, 3 h)\n- ASG-011 Scenario pack 02: scenarios 11-20 (Assignment, 3 h)\n- ASG-012 Scenario pack 03: scenarios 21-30 (Assignment, 3 h)\n- ASG-013 Scenario pack 04: scenarios 31-40 (Assignment, 3 h)\n- ASG-014 Scenario pack 05: scenarios 41-50 (Assignment, 3 h)\n- ASG-015 Scenario pack 06: scenarios 51-60 (Assignment, 3 h)\n- ASG-016 Scenario pack 07: scenarios 61-70 (Assignment, 3 h)\n- ASG-017 Scenario pack 08: scenarios 71-80 (Assignment, 3 h)\n- ASG-018 Scenario pack 09: scenarios 81-90 (Assignment, 3 h)\n- ASG-019 Scenario pack 10: scenarios 91-100 (Assignment, 3 h)\n\n### TOPIC-060 Document Flow Exercises\n\nTopics: For every document: what is generated, why, which module owns it, what data changes, what accounting impact occurs, how to troubleshoot it\n\n- EX-031 Document-flow exercise 2: strategic procurement with contract (Practical Exercise, 2 h)\n- EX-032 Document-flow exercise 3: subcontracting, consignment and stock transport (Practical Exercise, 3 h)\n- ASM-040 Real-world projects assessment (Assessment, 2 h)\n\n## Module 41 - Expert Consulting (V12 - Advanced Consulting)\n\n### TOPIC-061 Enterprise Procurement Architecture\n\nTopics: Enterprise procurement architecture; Global procurement; Central procurement; Multi-country procurement; Intercompany procurement; Shared services; Supplier governance; Procurement compliance; Procurement controls; Process optimization; Procurement automation; SAP MM solution architecture; Enterprise transformation\n\n- THY-066 Global, central and multi-country procurement (Theory, 4 h)\n- THY-067 Governance, compliance, controls and optimization (Theory, 3 h)\n- ASG-020 Assignment: solution architecture for a client brief (Assignment, 6 h)\n\n### TOPIC-062 Integration Architecture, Cloud and Extensibility\n\nTopics: Integration architecture; API-based procurement; Fiori architecture concepts; Cloud ERP procurement concepts; SAP S/4HANA Cloud procurement concepts; Extensibility; Clean Core principles; Side-by-side extension concepts\n\n- THY-068 Integration architecture and API-based procurement (Theory, 3 h)\n- THY-069 Cloud ERP, clean core and extensibility (Theory, 3 h)\n\n### TOPIC-063 SAP MM and Ariba\n\nTopics: SAP Ariba overview; Supplier collaboration; Sourcing; Contracts; Buying; Invoicing; SAP S/4HANA integration; Procurement network concepts; SAP Business Network; Supplier lifecycle; Integration architecture\n\n- THY-070 SAP Ariba and SAP Business Network with S/4HANA (Theory, 3 h)\n- ASG-021 Assignment: Ariba and MM responsibility map (Assignment, 2 h)\n\n### TOPIC-064 SAP MM Transaction Code Curriculum\n\nTopics: T-codes by master data, purchasing, inventory, invoice verification, physical inventory, valuation, reporting, configuration and troubleshooting; For each: purpose, business scenario, input, output, related transaction, S/4HANA/Fiori alternative\n\n- DOC-007 Transaction reference: master data, purchasing and inventory (Documentation, 4 h)\n- DOC-008 Transaction reference: invoice verification, physical inventory and valuation (Documentation, 3 h)\n- DOC-009 Transaction reference: reporting, configuration and troubleshooting (Documentation, 3 h)\n\n### TOPIC-065 Interview Preparation\n\nTopics: For every question: question, short answer, detailed answer, real-world example, configuration relevance, common mistake\n\n- INT-001 Interview preparation: Basic MM questions (Interview Preparation, 2 h)\n- INT-002 Interview preparation: Procurement questions (Interview Preparation, 2 h)\n- INT-003 Interview preparation: Purchasing configuration questions (Interview Preparation, 2 h)\n- INT-004 Interview preparation: Inventory questions (Interview Preparation, 2 h)\n- INT-005 Interview preparation: Invoice verification questions (Interview Preparation, 2 h)\n- INT-006 Interview preparation: Valuation questions (Interview Preparation, 2 h)\n- INT-007 Interview preparation: Account determination questions (Interview Preparation, 2 h)\n- INT-008 Interview preparation: Integration questions (Interview Preparation, 2 h)\n- INT-009 Interview preparation: S/4HANA questions (Interview Preparation, 2 h)\n- INT-010 Interview preparation: Scenario-based questions (Interview Preparation, 3 h)\n- INT-011 Interview preparation: Production support questions (Interview Preparation, 2 h)\n- INT-012 Interview preparation: Troubleshooting questions (Interview Preparation, 2 h)\n- INT-013 Interview preparation: Consultant-level questions (Interview Preparation, 3 h)\n\n### TOPIC-066 Career Preparation\n\nTopics: Resume; LinkedIn headline, about section, skills and project descriptions; HR, functional, scenario, configuration, S/4HANA and support interview questions; Project explanation: business requirement, my role, configuration, integration, testing, issue, solution, business result\n\n- DOC-010 SAP MM consultant resume (Documentation, 3 h)\n- DOC-011 LinkedIn profile (Documentation, 2 h)\n- INT-014 Interview preparation: HR questions (Interview Preparation, 2 h)\n- ASG-022 Project explanation practice (Assignment, 3 h)\n- ASM-041 Mock interviews: HR, functional and client simulation (Assessment, 3 h)\n\n## Module 42 - Final Capstone (V13 - Capstone)\n\n### TOPIC-067 Capstone: SAP MM Implementation for Global Manufacturing Corporation\n\nTopics: Business: multiple plants, storage locations and suppliers; raw materials, semi-finished and finished products; domestic and international procurement; subcontracting; consignment; services; stock transfers; MRP-driven procurement. Nine processes and twenty-one deliverables\n\n- CAP-001 Business requirements and organization structure (Capstone Task, 6 h)\n- CAP-002 Process design and process flow diagrams (Capstone Task, 5 h)\n- CAP-003 Master data: materials, suppliers and purchasing data (Capstone Task, 8 h)\n- CAP-004 Purchasing configuration, pricing and approval workflow (Capstone Task, 10 h)\n- CAP-005 Inventory, valuation and invoice verification configuration (Capstone Task, 8 h)\n- CAP-006 Configuration workbook (Capstone Task, 5 h)\n- CAP-007 Processes 1 and 2: standard P2P and RFQ to supplier selection to PO (Capstone Task, 6 h)\n- CAP-008 Processes 3 and 4: subcontracting and consignment (Capstone Task, 6 h)\n- CAP-009 Processes 5 and 6: stock transport order and service procurement (Capstone Task, 6 h)\n- CAP-010 Processes 7, 8 and 9: MRP procurement, physical inventory and month-end closing (Capstone Task, 8 h)\n- CAP-011 Test scripts: procurement, inventory and integration (Capstone Task, 8 h)\n- CAP-012 Functional specifications (Capstone Task, 4 h)\n- CAP-013 Migration strategy, cutover plan and go-live checklist (Capstone Task, 6 h)\n- CAP-014 Production support runbook, troubleshooting guide and RCA examples (Capstone Task, 5 h)\n- CAP-015 Training material and end-user documentation (Capstone Task, 5 h)\n- CAP-016 Final solution architecture and final project presentation (Capstone Task, 5 h)\n- ASM-042 Final assessment: solution design (Assessment, 3 h)\n",
   "parent": "Wiki"
  }
 ]
}
