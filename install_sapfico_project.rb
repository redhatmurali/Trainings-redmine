# SAP FICO Complete Training Basic to Expert - one-shot Redmine installer
#
# Put this file and sapfico_issues.csv in the same folder. Run on the Redmine server,
# from the Redmine root directory, as the Redmine OS user:
#
#   STUDENTS=alice,bob INSTRUCTORS=admin \
#     bundle exec rails runner -e production /path/to/install_sapfico_project.rb
#
# Environment variables (all optional):
#   CSV            path to sapfico_issues.csv (default: same folder as this script)
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
csv_path   = File.join(course_dir, 'sapfico_issues.csv') if csv_path.empty?
halt("not found: #{csv_path} (set CSV=/path/to/sapfico_issues.csv)") unless File.file?(csv_path)

# The project definition (fields, queries, wiki pages) is embedded at the end of this file.
embedded = File.read(File.expand_path(__FILE__), :encoding => 'utf-8').split("\n__END__\n", 2)[1]
halt('embedded project definition missing from this script') if embedded.to_s.strip.empty?
course = JSON.parse(embedded)
$tag   = course['tag'].to_s.empty? ? 'course' : course['tag']
rows   = CSV.read(csv_path, :headers => true, :encoding => 'bom|utf-8').map(&:to_h)
halt('sapfico_issues.csv is empty') if rows.empty?
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
 "tag": "sapfico",
 "project": {
  "name": "SAP FICO — Complete Training Basic to Expert",
  "identifier": "sap-fico-complete-basic-to-expert",
  "description": "SAP Finance and Controlling programme from accounting beginner to SAP FICO / S/4HANA Finance consultant: accounting, FI, CO, configuration, business processes, integration, S/4HANA, testing, migration, implementation and support, across 30 phases ending in a full implementation capstone. Every topic follows Concept -> Business Scenario -> Configuration -> Transaction -> Accounting Impact -> Testing -> Troubleshooting -> Documentation -> Assessment. One shared project; every student has a personal copy of each issue."
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
   "name": "Accounting",
   "kind": "work"
  },
  {
   "name": "FI",
   "kind": "work"
  },
  {
   "name": "CO",
   "kind": "work"
  },
  {
   "name": "Configuration",
   "kind": "work"
  },
  {
   "name": "Business Process",
   "kind": "work"
  },
  {
   "name": "Lab",
   "kind": "work"
  },
  {
   "name": "Scenario",
   "kind": "work"
  },
  {
   "name": "Troubleshooting",
   "kind": "work"
  },
  {
   "name": "Testing",
   "kind": "work"
  },
  {
   "name": "Implementation",
   "kind": "work"
  },
  {
   "name": "Support",
   "kind": "work"
  },
  {
   "name": "Assessment",
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
  "Troubleshooting",
  "Documentation",
  "Testing",
  "Review",
  "Accounting Practice",
  "Business Process"
 ],
 "versions": [
  "V01.0 Accounting Fundamentals",
  "V02.0 SAP Fundamentals",
  "V03.0 SAP Navigation",
  "V04.0 Enterprise Structure",
  "V05.0 FI General Ledger",
  "V06.0 Accounts Payable",
  "V07.0 Accounts Receivable",
  "V08.0 Bank Accounting",
  "V09.0 Asset Accounting",
  "V10.0 Tax",
  "V11.0 Financial Closing",
  "V12.0 CO Fundamentals",
  "V13.0 Cost Center Accounting",
  "V14.0 Internal Orders",
  "V15.0 Profit Center Accounting",
  "V16.0 Product Costing",
  "V17.0 CO-PA",
  "V18.0 FI-MM Integration",
  "V19.0 FI-SD Integration",
  "V20.0 FI-AA/CO Integration",
  "V21.0 S/4HANA Finance",
  "V22.0 Universal Journal",
  "V23.0 Business Partner",
  "V24.0 Fiori & Reporting",
  "V25.0 Migration",
  "V26.0 Testing",
  "V27.0 Implementation",
  "V28.0 Production Support",
  "V29.0 Advanced Consulting",
  "V30.0 Final Capstone"
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
   "name": "Transaction Code",
   "format": "list",
   "multiple": true,
   "trackers": "all",
   "csv": "Transaction Code",
   "sort": true
  },
  {
   "name": "SAP Version",
   "format": "string",
   "trackers": "all",
   "csv": "SAP Version"
  },
  {
   "name": "S/4HANA Relevance",
   "format": "list",
   "trackers": "all",
   "values": [
    "New in S/4HANA",
    "Changed in S/4HANA",
    "Same concept as ECC",
    "Not version specific",
    "Not system specific"
   ],
   "csv": "S/4HANA Relevance"
  },
  {
   "name": "Business Process",
   "format": "list",
   "trackers": "all",
   "values": [
    "None",
    "Procure to Pay",
    "Order to Cash",
    "Record to Report",
    "Asset Lifecycle",
    "Financial Closing",
    "Management Accounting"
   ],
   "csv": "Business Process"
  },
  {
   "name": "Integration Module",
   "format": "list",
   "trackers": "all",
   "values": [
    "None",
    "MM",
    "SD",
    "AA",
    "CO",
    "Bank"
   ],
   "csv": "Integration Module"
  },
  {
   "name": "Skill Level",
   "format": "list",
   "trackers": "all",
   "csv": "Skill Level",
   "sort": true
  },
  {
   "name": "Skill Track",
   "format": "list",
   "trackers": "all",
   "values": [
    "Accounting",
    "FI",
    "CO",
    "Consultant",
    "S/4HANA"
   ],
   "csv": "Skill Track"
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
    "Capstone",
    "Scenario"
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
      "tracker:Lab+FI+CO+Configuration+Business Process+Scenario"
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
   "name": "Dashboard: Accounting skills",
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
      "Accounting"
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
   "name": "Dashboard: FI skills",
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
      "FI"
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
   "name": "Dashboard: CO skills",
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
      "CO"
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
   "name": "Dashboard: Consultant skills",
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
      "Consultant"
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
   "name": "Dashboard: S/4HANA skills",
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
      "S/4HANA"
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
   "name": "Dashboard: projects and capstone",
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
      "tracker:Project+Capstone+Scenario"
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
   "text": "# SAP FICO - Complete Training Basic to Expert\n\nSAP Finance and Controlling programme from accounting beginner to SAP FICO / S/4HANA Finance consultant: accounting, FI, CO, configuration, business processes, integration, S/4HANA, testing, migration, implementation and support, across 30 phases ending in a full implementation capstone. Every topic follows Concept -> Business Scenario -> Configuration -> Transaction -> Accounting Impact -> Testing -> Troubleshooting -> Documentation -> Assessment. One shared project; every student has a personal copy of each issue.\n\n## How to work an issue\n\n1. Open your next issue from the saved query *My next tasks*.\n2. Set the status to **In Progress** and do the steps. Log time at the end of every session.\n3. Set **Testing**, check every acceptance criterion, attach the evidence.\n4. Set **Review**. The instructor sets **Completed** or **Reopened**.\n\n## Pages\n\n- [[Training_System]]\n- [[Course_Company]]\n- [[Month_End_Checklist]]\n- [[Document_Templates]]\n- [[Troubleshooting_Report]]\n- [[Workflow_and_Statuses]]\n- [[Assessment_and_Grading]]\n- [[Evidence_Standards]]\n- [[Dashboard_Guide]]\n- [[Skill_Matrix]]\n- [[Transaction_Code_Index]]\n- [[Module_Index]]"
  },
  {
   "title": "Training_System",
   "text": "# Training system\n\nPhase 1 needs only the accounting workbook. From phase 2 every student needs a user on an SAP S/4HANA training or practice system with configuration rights in a training client, plus the Fiori launchpad. The instructor provides the system, the workbook, the legacy data files for migration, the bank statement file and the prepared error cases for the troubleshooting scenarios.\n\nTransaction codes in the issues are SAP GUI codes; some differ by release or have been replaced by Fiori apps in S/4HANA. Where a code is not available on your release, use the Fiori app for the same function.",
   "parent": "Wiki"
  },
  {
   "title": "Course_Company",
   "text": "# Course company\n\n**Global Manufacturing Pvt Ltd** is used for the labs and the configuration project; **Global Manufacturing Corporation** is the capstone company.\n\n| Item | Design |\n|---|---|\n| Business | Manufacturer of industrial components, sells to distributors and direct customers |\n| Legal entities | One company code in India for the labs; a second country in the solution design task |\n| Currency | INR as company code currency, USD as group currency |\n| Fiscal year | April to March, twelve periods and four special periods |\n| Plants | One manufacturing plant and one distribution warehouse |\n| Reporting | Profit centres by product line, segments by business division |\n| Tax | GST on purchases and sales, tax deducted at source on services |\n| Controlling | Production, service and administration cost centres; marketing and investment orders |",
   "parent": "Wiki"
  },
  {
   "title": "Month_End_Checklist",
   "text": "# Month-end closing checklist\n\n| Step | Activity | Typical transaction |\n|---|---|---|\n| 1 | AP closing: invoices posted, payment run complete, GR/IR analysed | FBL1N, F110, MR11 |\n| 2 | AR closing: billing complete, incoming payments applied, dunning | FBL5N, F-28, F150 |\n| 3 | Asset closing: acquisitions capitalised, settlements run | AIBU, AW01N |\n| 4 | Bank reconciliation | FF67 or FF_5, FEBAN |\n| 5 | Accruals and deferrals | FBS1, F.81 |\n| 6 | Foreign currency valuation | FAGL_FCV |\n| 7 | Depreciation run | AFAB |\n| 8 | GR/IR regrouping | MR11, FAGLF101 |\n| 9 | Controlling: allocations and settlements | KSV5, KSU5, KO88 |\n| 10 | GL closing: clear open items, close the period | F.13, OB52 |\n| 11 | Financial statements and reconciliation | F.01, S_ALR_87012284 |\n\nYear end adds: asset fiscal year close, balance carryforward, opening of the new year and audit schedules.",
   "parent": "Wiki"
  },
  {
   "title": "Document_Templates",
   "text": "# Document templates\n\n**Business blueprint / design:** scope; organization; master data; processes; reports; interfaces; controls; open points.\n\n**Fit-gap:** requirement; standard fit; gap; options; decision; effort.\n\n**Configuration document:** area; IMG path or app; setting and values; business reason; unit test reference.\n\n**Functional specification:** purpose; process context; logic; selection; output; authorization; error handling; test cases.\n\n**Test script:** id; objective; preconditions; steps; test data; expected result; expected accounting entries; actual result; evidence; status.\n\n**Cutover plan:** task; owner; start; duration; dependency; verification; fallback.\n\n**Data migration plan:** object; source; cleansing; mapping; tool; sequence; validation; sign-off.\n\n**Go-live checklist:** readiness item; owner; evidence; go or no-go.\n\n**Support runbook:** process; schedule; checks; known errors; contacts; escalation.\n\n**Root cause analysis:** incident; timeline; impact; root cause; corrective action; preventive action.\n\n**Training material:** purpose; steps with screens; common errors; who to contact.",
   "parent": "Wiki"
  },
  {
   "title": "Troubleshooting_Report",
   "text": "# Troubleshooting report\n\nEvery troubleshooting issue is closed with these eight sections:\n\n1. **Problem** - the message number and text and what the user was doing\n2. **Business impact** - what cannot be done and who is affected\n3. **Evidence** - screenshots, document numbers, settings seen\n4. **Root cause** - the configuration or master data behind the error\n5. **Configuration** - where the setting lives\n6. **Fix** - the change made\n7. **Validation** - the original transaction now works\n8. **Prevention** - what stops it happening again",
   "parent": "Wiki"
  },
  {
   "title": "Workflow_and_Statuses",
   "text": "# Workflow and statuses\n\n| Status | Meaning |\n|---|---|\n| New | Template or unassigned |\n| Assigned | Belongs to a student, not started |\n| In Progress | Being worked on |\n| Blocked | Cannot continue; a note states the blocker |\n| Testing | Steps done; student checks the acceptance criteria and collects evidence |\n| Review | Submitted to the instructor |\n| Completed | Approved by the instructor |\n| Reopened | Changes requested |\n| Rejected | Waived or not applicable (instructor only) |\n\nPrerequisites are *blocked by* relations: an issue cannot be closed while its blocker is open.",
   "parent": "Wiki"
  },
  {
   "title": "Assessment_and_Grading",
   "text": "# Assessment and grading\n\n| Type | Covers |\n|---|---|\n| Accounting assessments | Journal entries, ledger, trial balance, financial statements |\n| SAP assessments | Configuration, transaction execution, business process |\n| Consultant assessments | Requirement analysis, solution design, configuration decisions, troubleshooting |\n| Scenario assessments | Understand requirement; identify SAP process; identify configuration; execute transaction; validate accounting impact; document solution |\n| Projects and capstone | Month-end, year-end, configuration project and the capstone, each scored 0-100 |\n\nPass mark 70. Programme grade: phase assessments 30 %, projects and scenarios 30 %, capstone 40 %. A student is not complete by finishing theory: every phase gate requires its labs and troubleshooting cases, and the programme requires the implementation project and the capstone.",
   "parent": "Wiki"
  },
  {
   "title": "Evidence_Standards",
   "text": "# Evidence standards\n\n| Evidence | Minimum content |\n|---|---|\n| Notes | Own words, one page, diagrams where useful |\n| Worked solution | Entries or statements with workings, checked against the workbook |\n| Document numbers + screenshots | Company code, document number, fiscal year and a screenshot of the result |\n| Configuration document entry | Area, path, values, business reason and test document number |\n| Process document + document numbers | Each step with its document number and accounting impact |\n| Test script + evidence | Script in the template with actual results and evidence per step |\n| Root cause report | The eight sections |\n| Ticket notes | Analysis, solution, user communication, closure |\n| Written deliverable | Document in the course template |\n| Project documentation | All project documents plus test evidence |\n| Scored result | Score and feedback recorded by the instructor |",
   "parent": "Wiki"
  },
  {
   "title": "Dashboard_Guide",
   "text": "# Dashboard guide\n\nThe dashboard is the set of saved queries in the issue list sidebar. Add them to *My page* as custom query blocks.\n\n| Section | Saved query |\n|---|---|\n| Course progress | Dashboard: overall completion; phase completion; module completion; labs completed; assessment completion |\n| FI skills | Dashboard: FI skills (grouped by category: General Ledger, Accounts Payable, Accounts Receivable, Asset Accounting, Bank Accounting, Tax, Closing) |\n| CO skills | Dashboard: CO skills (Cost Center, Internal Order, Profit Center, Product Costing, CO-PA) |\n| Consultant skills | Dashboard: Consultant skills (Implementation, integration, Testing, Migration, Support, ...) |\n| S/4HANA skills | Dashboard: S/4HANA skills (S/4HANA, Business Partner, Fiori) |\n| Accounting | Dashboard: Accounting skills |\n\nFor % done to follow the status, set *Administration > Settings > Issue tracking > Calculate the issue done ratio* to *Use the issue status* (global setting).",
   "parent": "Wiki"
  },
  {
   "title": "Skill_Matrix",
   "text": "# Skill matrix\n\n| Area | Track | Level | Modules | Tasks | Hours |\n|---|---|---|---|---|---|\n| Accounting Basics | Accounting | Level 1 - Accounting & SAP Foundation | MOD-01, MOD-02, MOD-03, MOD-04, MOD-05, MOD-06 | 29 | 78 |\n| SAP Basics | Consultant | Level 1 - Accounting & SAP Foundation | MOD-07, MOD-08 | 11 | 24 |\n| Enterprise Structure | FI | Level 1 - Accounting & SAP Foundation | MOD-09 | 10 | 24 |\n| General Ledger | FI | Level 2 - SAP FI & CO Core | MOD-10, MOD-11 | 16 | 35 |\n| Accounts Payable | FI | Level 2 - SAP FI & CO Core | MOD-12 | 10 | 22 |\n| Accounts Receivable | FI | Level 2 - SAP FI & CO Core | MOD-13 | 10 | 22 |\n| Bank Accounting | FI | Level 2 - SAP FI & CO Core | MOD-14, MOD-15 | 12 | 32 |\n| Asset Accounting | FI | Level 2 - SAP FI & CO Core | MOD-16, MOD-17 | 13 | 35 |\n| Tax | FI | Level 2 - SAP FI & CO Core | MOD-18 | 9 | 20 |\n| Closing | FI | Level 2 - SAP FI & CO Core | MOD-19 | 15 | 52 |\n| CO Basics | CO | Level 2 - SAP FI & CO Core | MOD-20 | 5 | 12 |\n| Cost Center | CO | Level 2 - SAP FI & CO Core | MOD-21 | 9 | 24 |\n| Internal Order | CO | Level 2 - SAP FI & CO Core | MOD-22 | 7 | 15 |\n| Profit Center | CO | Level 2 - SAP FI & CO Core | MOD-23 | 6 | 14 |\n| Product Costing | CO | Level 2 - SAP FI & CO Core | MOD-24 | 9 | 27 |\n| CO-PA | CO | Level 2 - SAP FI & CO Core | MOD-25 | 6 | 17 |\n| FI-MM Integration | Consultant | Level 3 - Implementation & Integration | MOD-26 | 9 | 25 |\n| FI-SD Integration | Consultant | Level 3 - Implementation & Integration | MOD-27 | 7 | 18 |\n| FI-CO Integration | Consultant | Level 3 - Implementation & Integration | MOD-28 | 7 | 19 |\n| S/4HANA | S/4HANA | Level 4 - S/4HANA Finance Expert | MOD-29, MOD-30, MOD-31, MOD-32, MOD-33, MOD-48 | 21 | 69 |\n| Business Partner | S/4HANA | Level 4 - S/4HANA Finance Expert | MOD-34 | 7 | 15 |\n| Reporting | FI | Level 3 - Implementation & Integration | MOD-35 | 4 | 11 |\n| Fiori | S/4HANA | Level 4 - S/4HANA Finance Expert | MOD-36 | 4 | 11 |\n| Migration | Consultant | Level 3 - Implementation & Integration | MOD-37 | 10 | 27 |\n| Testing | Consultant | Level 3 - Implementation & Integration | MOD-38 | 6 | 18 |\n| Implementation | Consultant | Level 3 - Implementation & Integration | MOD-39, MOD-40, MOD-41, MOD-42 | 15 | 66 |\n| Support | Consultant | Level 3 - Implementation & Integration | MOD-43, MOD-44 | 17 | 40 |\n| Business Scenarios | Consultant | Level 3 - Implementation & Integration | MOD-45, MOD-46, MOD-47 | 12 | 50 |\n| Career | Consultant | Level 3 - Implementation & Integration | MOD-49 | 5 | 18 |\n| Capstone | Consultant | Level 4 - S/4HANA Finance Expert | MOD-50 | 13 | 87 |",
   "parent": "Wiki"
  },
  {
   "title": "Transaction_Code_Index",
   "text": "# Transaction code index\n\nGrouped by where each code is used. The six-part reference (purpose, when used, input, output, business scenario, common errors) is written by the student in the transaction reference tasks of phase 29.\n\n| Transaction | Modules |\n|---|---|\n| /UI2/FLP | MOD-36 |\n| 3KEH | MOD-23 |\n| ABAON | MOD-17 |\n| ABAVN | MOD-17 |\n| ABLDT | MOD-32, MOD-37 |\n| ABUMN | MOD-17 |\n| ABZON | MOD-17 |\n| ACDOCA | MOD-28 |\n| AFAB | MOD-17, MOD-19, MOD-28, MOD-32, MOD-44, MOD-45, MOD-50 |\n| AFAMA | MOD-16 |\n| AIAB | MOD-17, MOD-28 |\n| AIBU | MOD-17, MOD-28 |\n| AJAB | MOD-19 |\n| AO90 | MOD-16 |\n| AR01 | MOD-17, MOD-35, MOD-37 |\n| AS01 | MOD-17, MOD-47 |\n| AS08 | MOD-16 |\n| AW01N | MOD-17, MOD-28, MOD-32 |\n| BP | MOD-12, MOD-13, MOD-34, MOD-47, MOD-50 |\n| BUC2 | MOD-34 |\n| BUCF | MOD-34 |\n| CA03 | MOD-24 |\n| CK11N | MOD-24, MOD-50 |\n| CK24 | MOD-24 |\n| CK40N | MOD-24 |\n| CS03 | MOD-24 |\n| EC08 | MOD-16 |\n| F-02 | MOD-11 |\n| F-03 | MOD-14, MOD-19 |\n| F-28 | MOD-13, MOD-27, MOD-45 |\n| F-29 | MOD-13 |\n| F-32 | MOD-13 |\n| F-37 | MOD-13 |\n| F-39 | MOD-13 |\n| F-44 | MOD-12 |\n| F-47 | MOD-12 |\n| F-48 | MOD-12 |\n| F-53 | MOD-12, MOD-18, MOD-26, MOD-31 |\n| F-54 | MOD-12 |\n| F-90 | MOD-17, MOD-32 |\n| F-92 | MOD-17 |\n| F.01 | MOD-19, MOD-35, MOD-45 |\n| F.07 | MOD-19 |\n| F.13 | MOD-19 |\n| F.14 | MOD-11 |\n| F.80 | MOD-11 |\n| F.81 | MOD-19 |\n| F110 | MOD-14, MOD-15, MOD-45, MOD-50 |\n| F150 | MOD-13 |\n| FAGL3KEH | MOD-23 |\n| FAGL_FCV | MOD-19, MOD-30 |\n| FAGLB03 | MOD-11, MOD-23, MOD-30, MOD-35, MOD-37 |\n| FAGLF101 | MOD-19 |\n| FAGLGVTR | MOD-19 |\n| FAGLL03 | MOD-35 |\n| FAGLL03H | MOD-33 |\n| FB01 | MOD-37 |\n| FB02 | MOD-11 |\n| FB03 | MOD-11, MOD-26, MOD-28, MOD-31, MOD-33, MOD-38, MOD-44 |\n| FB08 | MOD-11 |\n| FB50 | MOD-11, MOD-22, MOD-28 |\n| FB50L | MOD-30, MOD-33 |\n| FB60 | MOD-12, MOD-15, MOD-18, MOD-31, MOD-34 |\n| FB65 | MOD-12 |\n| FB70 | MOD-13 |\n| FB75 | MOD-13 |\n| FBD1 | MOD-11 |\n| FBKP | MOD-13 |\n| FBL1N | MOD-12, MOD-37 |\n| FBL3N | MOD-11, MOD-14, MOD-26 |\n| FBL5N | MOD-13, MOD-27, MOD-37 |\n| FBMP | MOD-13 |\n| FBN1 | MOD-10 |\n| FBS1 | MOD-19 |\n| FBV0 | MOD-11 |\n| FBZP | MOD-12, MOD-14, MOD-15, MOD-44 |\n| FCHN | MOD-15 |\n| FD10N | MOD-13 |\n| FD11 | MOD-13 |\n| FEBAN | MOD-14 |\n| FF67 | MOD-14, MOD-15 |\n| FF_5 | MOD-14 |\n| FGI1 | MOD-35 |\n| FI01 | MOD-14 |\n| FI12 | MOD-14, MOD-47 |\n| FINSC_LEDGER | MOD-29, MOD-30, MOD-33 |\n| FK10N | MOD-12 |\n| FKMT | MOD-11 |\n| FLBPC1 | MOD-34 |\n| FLBPD1 | MOD-34 |\n| FS00 | MOD-10, MOD-14, MOD-20, MOD-47 |\n| FTXP | MOD-18 |\n| GGB0 | MOD-48 |\n| GGB1 | MOD-48 |\n| GSP_KD | MOD-31, MOD-44 |\n| GSP_LZ1 | MOD-31 |\n| GSP_LZ2 | MOD-31 |\n| J1IG | MOD-18 |\n| KA23 | MOD-20 |\n| KANK | MOD-20 |\n| KB11N | MOD-21 |\n| KB21N | MOD-21 |\n| KB31N | MOD-21 |\n| KCH1 | MOD-23 |\n| KE21N | MOD-25 |\n| KE24 | MOD-25 |\n| KE30 | MOD-25, MOD-50 |\n| KE4I | MOD-25 |\n| KE51 | MOD-09, MOD-23, MOD-47 |\n| KE52 | MOD-23 |\n| KE5Z | MOD-23 |\n| KEA0 | MOD-25 |\n| KEDR | MOD-25 |\n| KEQ3 | MOD-25 |\n| KEU1 | MOD-25 |\n| KEU5 | MOD-25 |\n| KK01 | MOD-21, MOD-47 |\n| KKF6N | MOD-24 |\n| KKS1 | MOD-24 |\n| KL01 | MOD-21, MOD-47 |\n| KO01 | MOD-22, MOD-28, MOD-47 |\n| KO02 | MOD-22 |\n| KO12 | MOD-22 |\n| KO22 | MOD-22 |\n| KO88 | MOD-22, MOD-24, MOD-28 |\n| KOB1 | MOD-22 |\n| KONK | MOD-22 |\n| KOT2 | MOD-22 |\n| KP06 | MOD-21 |\n| KP26 | MOD-21 |\n| KS01 | MOD-21, MOD-47 |\n| KSB1 | MOD-21, MOD-28, MOD-33, MOD-35 |\n| KSH1 | MOD-21 |\n| KSU1 | MOD-21 |\n| KSU5 | MOD-21 |\n| KSV1 | MOD-21 |\n| KSV5 | MOD-21 |\n| KZS2 | MOD-24 |\n| LSMW | MOD-37 |\n| LTMC | MOD-37, MOD-50 |\n| LTMOM | MOD-37 |\n| MB5S | MOD-26 |\n| MDS_PPO2 | MOD-34 |\n| ME21N | MOD-26, MOD-28, MOD-45 |\n| ME51N | MOD-26 |\n| MIGO | MOD-26, MOD-28, MOD-45 |\n| MIRO | MOD-26, MOD-28, MOD-45 |\n| MM03 | MOD-24 |\n| MR11 | MOD-19, MOD-26 |\n| OADB | MOD-16, MOD-32 |\n| OAOA | MOD-16 |\n| OAOB | MOD-16 |\n| OAYZ | MOD-16 |\n| OB07 | MOD-10 |\n| OB08 | MOD-10, MOD-19, MOD-44 |\n| OB13 | MOD-09 |\n| OB22 | MOD-30 |\n| OB28 | MOD-48 |\n| OB29 | MOD-09 |\n| OB37 | MOD-09 |\n| OB40 | MOD-18 |\n| OB41 | MOD-10 |\n| OB45 | MOD-09 |\n| OB52 | MOD-09, MOD-19, MOD-44 |\n| OB57 | MOD-10 |\n| OB58 | MOD-19 |\n| OB59 | MOD-19 |\n| OB62 | MOD-09 |\n| OB74 | MOD-19 |\n| OBA0 | MOD-10 |\n| OBA1 | MOD-19 |\n| OBA4 | MOD-10 |\n| OBA7 | MOD-10 |\n| OBAT | MOD-13 |\n| OBB8 | MOD-12 |\n| OBBG | MOD-18 |\n| OBBH | MOD-10, MOD-48 |\n| OBBO | MOD-09 |\n| OBBP | MOD-09 |\n| OBBS | MOD-10 |\n| OBC4 | MOD-10 |\n| OBC5 | MOD-10 |\n| OBD3 | MOD-12 |\n| OBD4 | MOD-09, MOD-10 |\n| OBQ3 | MOD-18 |\n| OBWW | MOD-18 |\n| OBY6 | MOD-09 |\n| OBYC | MOD-26, MOD-44 |\n| OKB9 | MOD-20 |\n| OKEON | MOD-21 |\n| OKKN | MOD-24 |\n| OKKP | MOD-09, MOD-20 |\n| OKO7 | MOD-22 |\n| OKOB | MOD-22 |\n| OKTZ | MOD-24 |\n| OMJJ | MOD-26 |\n| OMSK | MOD-26 |\n| OMWD | MOD-26 |\n| OV25 | MOD-27 |\n| OVK1 | MOD-27 |\n| OVK5 | MOD-27 |\n| OVK6 | MOD-27 |\n| OX02 | MOD-09 |\n| OX03 | MOD-09 |\n| OX15 | MOD-09 |\n| OX16 | MOD-09 |\n| OX19 | MOD-09 |\n| PFCG | MOD-07, MOD-41, MOD-46 |\n| S_ALR_87012082 | MOD-35 |\n| S_ALR_87012085 | MOD-12 |\n| S_ALR_87012168 | MOD-13, MOD-35 |\n| S_ALR_87012172 | MOD-35 |\n| S_ALR_87012277 | MOD-35 |\n| S_ALR_87012284 | MOD-35 |\n| S_ALR_87012993 | MOD-22 |\n| S_ALR_87013326 | MOD-23, MOD-35 |\n| S_ALR_87013611 | MOD-21, MOD-35 |\n| SE10 | MOD-39, MOD-44 |\n| SE16H | MOD-33 |\n| SE16N | MOD-07, MOD-08, MOD-28, MOD-33, MOD-37, MOD-38, MOD-43, MOD-46 |\n| SE38 | MOD-46 |\n| SM21 | MOD-43, MOD-46 |\n| SM37 | MOD-08, MOD-43, MOD-46 |\n| SPRO | MOD-09, MOD-29, MOD-39, MOD-42, MOD-46, MOD-48, MOD-50 |\n| ST22 | MOD-43, MOD-46 |\n| STMS | MOD-07, MOD-39, MOD-43, MOD-44, MOD-46 |\n| SU01 | MOD-07, MOD-41, MOD-46 |\n| SU3 | MOD-08 |\n| SU53 | MOD-41, MOD-43 |\n| SUIM | MOD-41 |\n| VA01 | MOD-27, MOD-45 |\n| VF01 | MOD-27, MOD-45 |\n| VF03 | MOD-25, MOD-27 |\n| VKOA | MOD-27 |\n| VL01N | MOD-27, MOD-45 |\n| XKN1 | MOD-12 |",
   "parent": "Wiki"
  },
  {
   "title": "Module_Index",
   "text": "# Module index\n\n## Phase 01 - Accounting Fundamentals\n\n### MOD-01 What Accounting Is\n\nTopics: What is accounting; Purpose of accounting; Accounting cycle; Assets; Liabilities; Equity; Revenue; Expenses; Income; Profit; Loss\n\n- THY-001 What accounting is and why businesses need it (Theory, 3 h)\n- ACC-001 Classify business transactions (Accounting, 3 h)\n\n### MOD-02 Debit and Credit\n\nTopics: Debit; Credit; Golden rules; Modern accounting rules; Account classification; Journal entries\n\n- THY-002 Debit, credit, the golden rules and the modern rules (Theory, 4 h)\n- ACC-002 Journal entry set 01: capital, cash and bank (10 entries) (Accounting, 2 h)\n- ACC-003 Journal entry set 02: purchases and suppliers (10 entries) (Accounting, 2 h)\n- ACC-004 Journal entry set 03: sales and customers (10 entries) (Accounting, 2 h)\n- ACC-005 Journal entry set 04: expenses and income (10 entries) (Accounting, 2 h)\n- ACC-006 Journal entry set 05: discounts, bad debts and adjustments (10 entries) (Accounting, 2 h)\n- ACC-007 Journal entry set 06: fixed assets and depreciation (10 entries) (Accounting, 2 h)\n- ACC-008 Journal entry set 07: advances, accruals and prepayments (10 entries) (Accounting, 2 h)\n- ACC-009 Journal entry set 08: taxes on purchases and sales (10 entries) (Accounting, 2 h)\n- ACC-010 Journal entry set 09: inventory and cost of goods sold (10 entries) (Accounting, 2 h)\n- ACC-011 Journal entry set 10: foreign currency, loans and mixed month (10 entries) (Accounting, 2 h)\n\n### MOD-03 The Accounting Cycle\n\nTopics: Transaction; Journal entry; Ledger; Trial balance; Adjustments; Profit and Loss; Balance Sheet; Financial closing\n\n- THY-003 The accounting cycle from transaction to closing (Theory, 3 h)\n- ACC-012 Post journal entries to ledger accounts (Accounting, 3 h)\n- ACC-013 Prepare a trial balance and find errors (Accounting, 3 h)\n- ACC-014 Adjustment entries and the adjusted trial balance (Accounting, 3 h)\n- ACC-015 Prepare the Profit and Loss account and the Balance Sheet (Accounting, 4 h)\n\n### MOD-04 Ledgers and Subledgers\n\nTopics: General Ledger; Subledger; Customer ledger; Vendor ledger; Asset ledger; Bank ledger; Control accounts; Entry View versus General Ledger View\n\n- THY-004 General ledger, subledgers and control accounts (Theory, 3 h)\n- ACC-016 Reconcile subledgers to control accounts (Accounting, 3 h)\n\n### MOD-05 Financial Statements\n\nTopics: Trial Balance; Profit and Loss Account; Balance Sheet; Cash Flow concepts; How transactions flow into financial statements\n\n- THY-005 Reading financial statements and cash flow concepts (Theory, 3 h)\n- ACC-017 Build statements for a trading company (Accounting, 4 h)\n\n### MOD-06 Payables, Receivables, Assets, Inventory and Cost Concepts\n\nTopics: Vendor; Supplier; Sundry creditors; Purchase invoice; Credit memo; Debit memo; Payment; Advance; Clearing; Outstanding; Aging; Customer; Sundry debtor; Sales invoice; Incoming payment; Dunning; Asset; Asset class; Acquisition; Capitalization; Depreciation; Transfer; Retirement; Sale; Scrapping; Asset under construction; Settlement; Inventory accounting; Cost concepts\n\n- THY-006 Accounts payable lifecycle (Theory, 2 h)\n- THY-007 Accounts receivable lifecycle (Theory, 2 h)\n- ACC-018 Payables and receivables exercise: invoices, payments, clearing and aging (Accounting, 3 h)\n- THY-008 Fixed asset lifecycle and depreciation methods (Theory, 3 h)\n- ACC-019 Asset lifecycle exercise (Accounting, 3 h)\n- THY-009 Inventory accounting and cost concepts (Theory, 3 h)\n- ASM-001 Phase 01 assessment: accounting (Assessment, 3 h)\n\n## Phase 02 - SAP Fundamentals\n\n### MOD-07 SAP Fundamentals\n\nTopics: SAP overview; ERP; SAP ECC; SAP S/4HANA; SAP GUI; SAP Fiori; Client; System; Mandant; User; Roles; Authorization; Transport system\n\n- THY-010 ERP, SAP ECC and SAP S/4HANA (Theory, 3 h)\n- THY-011 Systems, clients and the transport landscape (Theory, 3 h)\n- THY-012 Users, roles and authorizations (Theory, 2 h)\n- LAB-001 Access the training system (Lab, 2 h)\n- ASM-002 Phase 02 assessment: SAP fundamentals (Assessment, 1 h)\n\n## Phase 03 - SAP Navigation\n\n### MOD-08 SAP Navigation\n\nTopics: SAP GUI; SAP Easy Access; Transaction codes; Fiori Launchpad; Favorites; Sessions; Search; Help; System information; User settings; Working without memorizing transaction codes\n\n- LAB-002 SAP GUI: Easy Access menu, command field, sessions and favourites (Lab, 3 h)\n- LAB-003 Help, search and system information (Lab, 2 h)\n- LAB-004 Fiori launchpad: tiles, search and personalization (Lab, 3 h)\n- THY-013 How to work without memorizing hundreds of codes (Theory, 2 h)\n- LAB-005 Display data with SE16N and read a line-item list (Lab, 2 h)\n- ASM-003 Phase 03 assessment: navigation practical (Assessment, 1 h)\n\n## Phase 04 - Enterprise Structure\n\n### MOD-09 SAP Organizational Structure\n\nTopics: Client; Company; Company Code; Controlling Area; Chart of Accounts; Fiscal Year Variant; Posting Period Variant; Business Area; Profit Center; Segment; Functional Area; Credit Control Area; Relationships between organizational objects\n\n- THY-014 Organizational units and how they relate (Theory, 4 h)\n- THY-015 The course company: Global Manufacturing Pvt Ltd (Theory, 2 h)\n- LAB-006 Create Company Code (Lab, 3 h)\n- LAB-007 Configure Chart of Accounts (Lab, 3 h)\n- LAB-008 Configure Fiscal Year (Lab, 2 h)\n- LAB-009 Configure Posting Period (Lab, 2 h)\n- CFG-001 Controlling area, profit centre and segment structure (Configuration, 3 h)\n- CFG-002 Business area, functional area and credit control area (Configuration, 2 h)\n- TSH-001 Scenario 01: company code not assigned to a chart of accounts or fiscal year variant (Troubleshooting, 1 h)\n- ASM-004 Phase 04 assessment: enterprise structure (Assessment, 2 h)\n\n## Phase 05 - FI General Ledger\n\n### MOD-10 General Ledger Configuration and Master Data\n\nTopics: Chart of Accounts; Account groups; G/L master; Account types; Document types; Number ranges; Posting keys; Field status; Fiscal year; Posting periods; Document header; Line items; Currency; Exchange rates\n\n- THY-016 G/L master data: chart of accounts segment and company code segment (Theory, 3 h)\n- LAB-010 Create G/L Account (Lab, 3 h)\n- THY-017 The SAP document: header, line items, document types, posting keys (Theory, 3 h)\n- CFG-003 Document types, number ranges and posting keys (Configuration, 3 h)\n- CFG-004 Field status groups and field status variant (Configuration, 2 h)\n- CFG-005 Tolerance groups for G/L accounts and employees (Configuration, 2 h)\n- CFG-006 Currencies and exchange rates (Configuration, 3 h)\n\n### MOD-11 Document Posting\n\nTopics: Journal entry; G/L posting; Customer posting; Vendor posting; Asset posting; Reversal; Adjustment; Parking; Hold; Recurring entries\n\n- LAB-011 Post Journal Entry (Lab, 3 h)\n- FI-001 Parking, hold, reversal and adjustment postings (FI, 3 h)\n- FI-002 Recurring entries, sample documents and account assignment models (FI, 2 h)\n- FI-003 Line items, balances and document changes (FI, 2 h)\n- TSH-002 Scenario 02: posting period closed (Troubleshooting, 1 h)\n- TSH-003 Scenario 03: account cannot be posted to directly (Troubleshooting, 1 h)\n- TSH-004 Scenario 04: field is required or suppressed unexpectedly (Troubleshooting, 1 h)\n- TSH-005 Scenario 05: number range missing for the document type and year (Troubleshooting, 1 h)\n- ASM-005 Phase 05 assessment: general ledger (Assessment, 2 h)\n\n## Phase 06 - Accounts Payable\n\n### MOD-12 Accounts Payable\n\nTopics: Vendor master / Business Partner; Vendor account groups; Invoice posting; Credit memo; Down payments; Outgoing payments; Clearing; Residual items; Partial payments; Special G/L; Withholding tax; Vendor aging\n\n- THY-018 Supplier master data and reconciliation accounts (Theory, 2 h)\n- CFG-007 Vendor groups, number ranges and payment terms (Configuration, 3 h)\n- LAB-012 Vendor Invoice (Lab, 3 h)\n- LAB-013 Outgoing Payment (Lab, 3 h)\n- FI-004 Vendor down payments (FI, 2 h)\n- BP-001 Accounts payable lifecycle (Business Process, 3 h)\n- TSH-006 Scenario 06: incorrect reconciliation account on a supplier (Troubleshooting, 2 h)\n- TSH-007 Scenario 07: vendor invoice error, balancing or tax (Troubleshooting, 1 h)\n- TSH-008 Scenario 08: payment terms give the wrong due date (Troubleshooting, 1 h)\n- ASM-006 Phase 06 assessment: accounts payable (Assessment, 2 h)\n\n## Phase 07 - Accounts Receivable\n\n### MOD-13 Accounts Receivable\n\nTopics: Customer master / Business Partner; Customer account groups; Billing integration; Incoming payment; Credit memo; Down payments; Clearing; Special G/L; Dunning; Customer aging; Bad debts\n\n- THY-019 Customer master data and credit control concepts (Theory, 2 h)\n- LAB-014 Customer Invoice (Lab, 3 h)\n- LAB-015 Incoming Payment (Lab, 3 h)\n- FI-005 Customer down payments and special G/L transactions (FI, 3 h)\n- CFG-008 Configure dunning (Configuration, 3 h)\n- LAB-016 Run dunning (Lab, 2 h)\n- FI-006 Bad debts and customer account analysis (FI, 2 h)\n- TSH-009 Scenario 09: customer payment cannot be cleared (Troubleshooting, 1 h)\n- TSH-010 Scenario 10: dunning run selects nothing (Troubleshooting, 1 h)\n- ASM-007 Phase 07 assessment: accounts receivable (Assessment, 2 h)\n\n## Phase 08 - Bank Accounting\n\n### MOD-14 Bank Accounting\n\nTopics: Bank master; House bank; Bank account; Bank GL; Incoming payments; Outgoing payments; Bank reconciliation; Electronic bank statements; Payment methods; Bank clearing\n\n- THY-020 Bank master, house bank and bank clearing accounts (Theory, 3 h)\n- CFG-009 House bank and bank G/L accounts (Configuration, 3 h)\n- LAB-017 Bank Reconciliation (Lab, 4 h)\n- THY-021 Electronic bank statement processing (Theory, 2 h)\n- LAB-018 Electronic bank statement upload and post-processing (Lab, 3 h)\n\n### MOD-15 Automatic Payment Program\n\nTopics: Payment methods; Payment terms; Due dates; Payment proposal; Payment run; Exceptions; Payment medium; Bank integration\n\n- CFG-010 Configure the payment program (Configuration, 4 h)\n- LAB-019 Automatic Payment (Lab, 4 h)\n- BP-002 Payment cycle: invoice to bank statement (Business Process, 3 h)\n- TSH-011 Scenario 11: automatic payment failure, no valid payment method (Troubleshooting, 2 h)\n- TSH-012 Scenario 12: items missing from the payment proposal (Troubleshooting, 1 h)\n- TSH-013 Scenario 13: bank statement lines not posted (Troubleshooting, 1 h)\n- ASM-008 Phase 08 assessment: bank accounting (Assessment, 2 h)\n\n## Phase 09 - Asset Accounting\n\n### MOD-16 Asset Accounting Configuration\n\nTopics: Asset classes; Number ranges; Account determination; Depreciation areas; Depreciation keys; Useful life; Straight-line depreciation; Declining balance concepts; Book depreciation; Tax depreciation concepts; Parallel depreciation\n\n- THY-022 Asset accounting structure: chart of depreciation, areas and classes (Theory, 3 h)\n- CFG-011 Chart of depreciation, depreciation areas and asset classes (Configuration, 4 h)\n- CFG-012 Account determination (Configuration, 3 h)\n- CFG-013 Depreciation keys and useful life (Configuration, 3 h)\n\n### MOD-17 Asset Transactions\n\nTopics: Asset acquisition; Asset transfer; Asset retirement; Asset sale; Asset scrapping; AuC; Settlement; Depreciation\n\n- LAB-020 Asset Acquisition (Lab, 3 h)\n- LAB-021 Asset Depreciation (Lab, 3 h)\n- FI-007 Asset transfer and asset under construction with settlement (FI, 3 h)\n- LAB-022 Asset Retirement (Lab, 3 h)\n- BP-003 Asset lifecycle: request to retirement (Business Process, 3 h)\n- TSH-014 Scenario 14: asset depreciation error in the run (Troubleshooting, 2 h)\n- TSH-015 Scenario 15: asset posting goes to the wrong G/L account (Troubleshooting, 1 h)\n- TSH-016 Scenario 16: asset subledger and G/L do not reconcile (Troubleshooting, 2 h)\n- ASM-009 Phase 09 assessment: asset accounting (Assessment, 2 h)\n\n## Phase 10 - Tax\n\n### MOD-18 Taxation\n\nTopics: Input tax; Output tax; Tax codes; Tax procedures; Tax jurisdiction concepts; Withholding tax; GST concepts; VAT concepts\n\n- THY-023 Tax on sales and purchases: procedures, codes and accounts (Theory, 3 h)\n- CFG-014 Tax procedure, tax codes and tax accounts (Configuration, 4 h)\n- THY-024 India GST example: CGST, SGST, IGST and input credit (Theory, 2 h)\n- THY-025 Withholding tax concepts and extended withholding tax (Theory, 2 h)\n- CFG-015 Configure extended withholding tax and post with deduction (Configuration, 4 h)\n- TSH-017 Scenario 17: missing tax code or tax account (Troubleshooting, 1 h)\n- TSH-018 Scenario 18: tax amount differs from the calculated amount (Troubleshooting, 1 h)\n- TSH-019 Scenario 19: withholding tax not deducted (Troubleshooting, 1 h)\n- ASM-010 Phase 10 assessment: tax (Assessment, 2 h)\n\n## Phase 11 - Financial Closing\n\n### MOD-19 General Ledger Closing\n\nTopics: Open item clearing; Accruals; Deferrals; Foreign currency valuation; GR/IR clearing; Depreciation; Asset closing; AP closing; AR closing; GL closing; Company code currency; Local currency; Group currency; Transaction currency; Translation; Valuation\n\n- THY-026 The closing process and why each step exists (Theory, 3 h)\n- FI-008 Open item clearing and automatic clearing (FI, 2 h)\n- FI-009 Accruals and deferrals with reversal (FI, 2 h)\n- CFG-016 Foreign currency valuation configuration (Configuration, 3 h)\n- LAB-023 Foreign currency valuation run (Lab, 3 h)\n- FI-010 GR/IR clearing and regrouping (FI, 2 h)\n- LAB-024 Month-End Closing (Lab, 6 h)\n- CFG-017 Financial statement version (Configuration, 3 h)\n- LAB-025 Year-End Closing (Lab, 4 h)\n- PROJECT-001 Month-end closing project: simulated company month (Project, 8 h)\n- PROJECT-002 Year-end closing project (Project, 8 h)\n- TSH-020 Scenario 20: foreign currency valuation posts nothing or to the wrong account (Troubleshooting, 2 h)\n- TSH-021 Scenario 21: balance carryforward wrong, profit not in retained earnings (Troubleshooting, 2 h)\n- TSH-022 Scenario 22: exchange rate missing or currency translation error (Troubleshooting, 1 h)\n- ASM-011 Phase 11 assessment: financial closing (Assessment, 3 h)\n\n## Phase 12 - CO Fundamentals\n\n### MOD-20 Controlling Fundamentals\n\nTopics: Management accounting; Cost; Revenue; Profit; Cost object; Cost center; Profit center; Internal order; Product cost; Profitability segment\n\n- THY-027 Management accounting versus financial accounting (Theory, 3 h)\n- THY-028 Cost elements in S/4HANA: primary and secondary as G/L accounts (Theory, 2 h)\n- CFG-018 Controlling area settings and number ranges (Configuration, 3 h)\n- CFG-019 Create primary and secondary cost elements and default account assignment (Configuration, 3 h)\n- ASM-012 Phase 12 assessment: CO fundamentals (Assessment, 1 h)\n\n## Phase 13 - Cost Center Accounting\n\n### MOD-21 Cost Center Accounting\n\nTopics: Cost center; Cost element concepts; Primary costs; Secondary costs; Allocations; Assessments; Distributions; Activity types; Statistical key figures\n\n- THY-029 Cost centres, hierarchy and categories (Theory, 2 h)\n- LAB-026 Cost Center (Lab, 3 h)\n- CO-001 Activity types, statistical key figures and planning (CO, 4 h)\n- CO-002 Distribution and assessment cycles (CO, 4 h)\n- CO-003 Direct activity allocation and reposting (CO, 2 h)\n- BP-004 Cost centre accounting scenario: plan, post, allocate, report (Business Process, 4 h)\n- TSH-023 Scenario 23: cost centre error, posting blocked or cost centre not valid on the date (Troubleshooting, 1 h)\n- TSH-024 Scenario 24: assessment cycle fails or allocates nothing (Troubleshooting, 2 h)\n- ASM-013 Phase 13 assessment: cost centre accounting (Assessment, 2 h)\n\n## Phase 14 - Internal Orders\n\n### MOD-22 Internal Orders\n\nTopics: Internal order; Order types; Planning; Budgeting; Actual postings; Settlement; Period-end processing\n\n- THY-030 Internal orders: real, statistical, overhead and investment (Theory, 2 h)\n- CFG-020 Order types, number ranges, settlement profile and budget profile (Configuration, 3 h)\n- LAB-027 Internal Order (Lab, 3 h)\n- CO-004 Settlement and period-end processing of orders (CO, 3 h)\n- TSH-025 Scenario 25: order settlement error (Troubleshooting, 1 h)\n- TSH-026 Scenario 26: budget exceeded message on posting (Troubleshooting, 1 h)\n- ASM-014 Phase 14 assessment: internal orders (Assessment, 2 h)\n\n## Phase 15 - Profit Center Accounting\n\n### MOD-23 Profit Center Accounting\n\nTopics: Profit center; Profit center hierarchy; Assignments; Revenue; Costs; Profit reporting; Segment reporting\n\n- THY-031 Profit centres and segment reporting in the general ledger (Theory, 3 h)\n- LAB-028 Profit Center (Lab, 3 h)\n- CFG-021 Default profit centres for balance sheet accounts (Configuration, 2 h)\n- CO-005 Profit centre and segment reporting (CO, 3 h)\n- TSH-027 Scenario 27: profit centre error, posting without profit centre (Troubleshooting, 1 h)\n- ASM-015 Phase 15 assessment: profit centre accounting (Assessment, 2 h)\n\n## Phase 16 - Product Costing\n\n### MOD-24 Product Costing\n\nTopics: Product cost; Material cost; Activity cost; Overhead; Cost estimate; Standard cost; Cost component structure; Variance\n\n- THY-032 Product cost planning: materials, activities and overhead (Theory, 4 h)\n- CFG-022 Costing variant, costing sheet and cost component structure (Configuration, 4 h)\n- LAB-029 Product Costing (Lab, 4 h)\n- CO-006 Costing run for many materials (CO, 2 h)\n- CO-007 Production order costs, variances and settlement (CO, 4 h)\n- BP-005 Product costing scenario: standard cost to variance (Business Process, 3 h)\n- TSH-028 Scenario 28: cost estimate error, missing price or activity rate (Troubleshooting, 2 h)\n- TSH-029 Scenario 29: variance settlement posts to an unexpected account (Troubleshooting, 2 h)\n- ASM-016 Phase 16 assessment: product costing (Assessment, 2 h)\n\n## Phase 17 - CO-PA\n\n### MOD-25 Profitability Analysis\n\nTopics: CO-PA; Account-based CO-PA; Characteristics; Value fields concepts; Profitability segments; Revenue analysis; Margin analysis\n\n- THY-033 Margin analysis: account-based profitability in S/4HANA (Theory, 3 h)\n- CFG-023 Operating concern, characteristics and derivation (Configuration, 4 h)\n- LAB-030 CO-PA (Lab, 4 h)\n- CO-008 Allocating overhead to profitability (CO, 2 h)\n- TSH-030 Scenario 30: revenue posting without profitability segment (Troubleshooting, 2 h)\n- ASM-017 Phase 17 assessment: profitability analysis (Assessment, 2 h)\n\n## Phase 18 - FI-MM Integration\n\n### MOD-26 FI-MM Integration\n\nTopics: Purchase requisition; Purchase order; Goods receipt; Invoice receipt; Payment; GR/IR; Inventory posting; Vendor liability; Price differences; Tax; Account determination\n\n- THY-034 Procure to pay and its accounting at each stage (Theory, 3 h)\n- THY-035 Automatic account determination for materials (Theory, 4 h)\n- CFG-024 Configure account determination (Configuration, 4 h)\n- LAB-031 FI-MM Integration (Lab, 4 h)\n- FI-011 Price differences and GR/IR analysis (FI, 3 h)\n- TSH-031 Scenario 31: account determination error on goods receipt (Troubleshooting, 2 h)\n- TSH-032 Scenario 32: GR/IR issue, balance does not clear (Troubleshooting, 2 h)\n- TSH-033 Scenario 33: invoice blocked for payment (Troubleshooting, 1 h)\n- ASM-018 Phase 18 assessment: FI-MM integration (Assessment, 2 h)\n\n## Phase 19 - FI-SD Integration\n\n### MOD-27 FI-SD Integration\n\nTopics: Sales order; Delivery; Goods issue; Billing; Accounting document; Customer receivable; Revenue; Tax; COGS; Account determination\n\n- THY-036 Order to cash and its accounting at each stage (Theory, 3 h)\n- THY-037 Revenue account determination (Theory, 3 h)\n- CFG-025 Configure revenue account determination (Configuration, 3 h)\n- LAB-032 FI-SD Integration (Lab, 4 h)\n- TSH-034 Scenario 34: billing document not released to accounting (Troubleshooting, 2 h)\n- TSH-035 Scenario 35: wrong revenue account or missing tax in billing (Troubleshooting, 1 h)\n- ASM-019 Phase 19 assessment: FI-SD integration (Assessment, 2 h)\n\n## Phase 20 - FI-AA/CO Integration\n\n### MOD-28 FI-AA and FI-CO Integration\n\nTopics: Asset procurement; Asset capitalization; Depreciation; Asset retirement; Asset settlement; Cost postings; Primary cost; Secondary cost; Cost center; Internal order; Profit center; Settlement; Universal Journal\n\n- THY-038 Asset procurement through purchasing and investment orders (Theory, 3 h)\n- LAB-033 Asset procurement with purchase order and capitalization (Lab, 4 h)\n- LAB-034 Investment order to asset under construction to asset (Lab, 4 h)\n- THY-039 FI and CO in one document: real-time integration (Theory, 2 h)\n- FI-012 Trace cost postings across FI and CO (FI, 3 h)\n- TSH-036 Scenario 36: asset not capitalised from the goods receipt (Troubleshooting, 1 h)\n- ASM-020 Phase 20 assessment: FI-AA and FI-CO integration (Assessment, 2 h)\n\n## Phase 21 - S/4HANA Finance\n\n### MOD-29 S/4HANA Finance Architecture\n\nTopics: S/4HANA architecture; Universal Journal; ACDOCA; Business Partner; New Asset Accounting; New GL; Embedded analytics; Fiori; Simplification; Real-time integration\n\n- THY-040 S/4HANA architecture and the simplification of finance (Theory, 4 h)\n- THY-041 New General Ledger concepts carried into S/4HANA (Theory, 3 h)\n\n### MOD-30 Ledgers and Parallel Accounting\n\nTopics: Leading ledger; Non-leading ledger; Parallel ledgers; Accounting principles; IFRS; Local GAAP; Parallel valuation\n\n- THY-042 Parallel accounting: ledger approach versus accounts approach (Theory, 3 h)\n- CFG-026 Configure ledgers, currencies and accounting principles (Configuration, 4 h)\n- LAB-035 Ledger-specific postings and reporting (Lab, 3 h)\n\n### MOD-31 Document Splitting\n\nTopics: Document splitting; Zero-balance; Profit center; Segment; Business area concepts; Configuration; Troubleshooting\n\n- THY-043 Document splitting: why, passive, active and zero balance (Theory, 4 h)\n- CFG-027 Configure document splitting (Configuration, 4 h)\n- LAB-036 Document splitting in practice (Lab, 4 h)\n- TSH-037 Scenario 37: document splitting error, balancing field not filled (Troubleshooting, 2 h)\n- TSH-038 Scenario 38: splitting rule not found for the business transaction (Troubleshooting, 2 h)\n\n### MOD-32 New Asset Accounting\n\nTopics: Ledger approach; Depreciation areas; Parallel valuation; Real-time integration; Asset accounting in S/4HANA\n\n- THY-044 New asset accounting: ledger approach and real-time posting (Theory, 3 h)\n- LAB-037 Parallel valuation of assets (Lab, 4 h)\n- ASM-021 Phase 21 assessment: S/4HANA finance (Assessment, 3 h)\n\n## Phase 22 - Universal Journal\n\n### MOD-33 Universal Journal\n\nTopics: ACDOCA; FI data; CO data; Actuals; Dimensions; Ledger; Currency; Profit center; Cost center; Segment; Why FI and CO integration is different in S/4HANA\n\n- THY-045 The universal journal: one line item table for FI, CO, AA, ML and profitability (Theory, 4 h)\n- LAB-038 S/4HANA Universal Journal (Lab, 4 h)\n- FI-013 Currencies in the universal journal (FI, 2 h)\n- FI-014 Extension ledgers and prediction or adjustment postings (FI, 2 h)\n- ASM-022 Phase 22 assessment: universal journal (Assessment, 2 h)\n\n## Phase 23 - Business Partner\n\n### MOD-34 Business Partner\n\nTopics: Business Partner; Customer role; Vendor role; BP roles; Number ranges; Groupings; Synchronization concepts\n\n- THY-046 The business partner model and customer-vendor integration (Theory, 3 h)\n- CFG-028 Business partner groupings, number ranges and role settings (Configuration, 3 h)\n- LAB-039 Business Partner (Lab, 3 h)\n- FI-015 Maintain, block and extend business partners (FI, 2 h)\n- TSH-039 Scenario 39: business partner created but supplier or customer missing (Troubleshooting, 2 h)\n- TSH-040 Scenario 40: partner number range or grouping error (Troubleshooting, 1 h)\n- ASM-023 Phase 23 assessment: business partner (Assessment, 1 h)\n\n## Phase 24 - Fiori & Reporting\n\n### MOD-35 Financial Reporting\n\nTopics: Balance Sheet; P&L; Trial Balance; GL reports; Customer reports; Vendor reports; Asset reports; Cost center reports; Profit center reports; Standard reports; Line-item reports; Financial statements; Drill-down reports; Fiori analytics; CDS-based reporting concepts\n\n- LAB-040 Financial statements and general ledger reports (Lab, 3 h)\n- LAB-041 Subledger reports: customers, vendors and assets (Lab, 3 h)\n- LAB-042 Controlling reports and drill-down reporting (Lab, 3 h)\n- THY-047 Embedded analytics and CDS-based reporting concepts (Theory, 2 h)\n\n### MOD-36 SAP Fiori for Finance\n\nTopics: Fiori Launchpad; Apps; Roles; Analytical apps; Transactional apps; Fact sheets; KPIs\n\n- THY-048 Fiori app types, catalogs, roles and the apps reference library (Theory, 2 h)\n- LAB-043 Fiori Finance (Lab, 4 h)\n- LAB-044 Fiori exercises: payables, receivables, assets and cost centres (Lab, 3 h)\n- ASM-024 Phase 24 assessment: reporting (Assessment, 2 h)\n\n## Phase 25 - Migration\n\n### MOD-37 SAP Data Migration\n\nTopics: Legacy data; Master data; Open items; Asset balances; GL balances; Customer balances; Vendor balances; Migration Cockpit; LSMW legacy concepts; BAPI; IDoc concepts; APIs; Templates; Data validation\n\n- THY-049 Migration objects, sequence and reconciliation (Theory, 3 h)\n- THY-050 Migration tools: Migration Cockpit, legacy LSMW, BAPI, IDoc and APIs (Theory, 2 h)\n- LAB-045 Migration (Lab, 5 h)\n- LAB-046 Migrate open items and balances (Lab, 4 h)\n- LAB-047 Migrate asset balances (Lab, 3 h)\n- DOC-001 Data migration plan (Documentation, 3 h)\n- THY-051 S/4HANA migration paths: new implementation, conversion and selective (Theory, 2 h)\n- TSH-041 Scenario 41: migration load fails validation (Troubleshooting, 1 h)\n- TSH-042 Scenario 42: opening balances do not reconcile after load (Troubleshooting, 2 h)\n- ASM-025 Phase 25 assessment: migration (Assessment, 2 h)\n\n## Phase 26 - Testing\n\n### MOD-38 Testing\n\nTopics: Unit testing; String testing; Integration testing; UAT; Regression testing; Negative testing; Performance testing; Test scripts; Test evidence; Defect management\n\n- THY-052 Test levels and what each one proves (Theory, 2 h)\n- TEST-001 Write unit test scripts for finance configuration (Testing, 3 h)\n- TEST-002 Write integration test scripts for procure to pay and order to cash (Testing, 4 h)\n- LAB-048 Testing (Lab, 4 h)\n- TEST-003 User acceptance testing and regression pack (Testing, 3 h)\n- ASM-026 Phase 26 assessment: testing (Assessment, 2 h)\n\n## Phase 27 - Implementation\n\n### MOD-39 Implementation Methodology\n\nTopics: ASAP concepts; SAP Activate; Fit-to-standard; Fit-gap; Explore; Realize; Deploy; Run; Project lifecycle from preparation to support; Configuration methodology from requirement to production\n\n- THY-053 ASAP and SAP Activate (Theory, 3 h)\n- THY-054 How consultants configure: requirement to production (Theory, 3 h)\n- IMPL-001 Fit-to-standard workshop and fit-gap document (Implementation, 4 h)\n- IMPL-002 IMG navigation and transport requests (Implementation, 3 h)\n\n### MOD-40 Implementation Documentation\n\nTopics: Business Blueprint; Fit-Gap document; Configuration document; Functional Specification; Test Script; Test Evidence; Cutover Plan; Data Migration Plan; Go-Live Checklist; Support Runbook; RCA; Training Material\n\n- DOC-002 Business blueprint or design document for finance (Documentation, 4 h)\n- DOC-003 Configuration document (Documentation, 3 h)\n- DOC-004 Functional specification for an enhancement (Documentation, 3 h)\n- DOC-005 Cutover plan and go-live checklist (Documentation, 4 h)\n- DOC-006 Training material for end users (Documentation, 3 h)\n\n### MOD-41 SAP FICO Security Concepts\n\nTopics: Roles; Authorization; Organizational restrictions; Company code security; Business Partner authorization; Finance transaction authorization; Segregation of Duties; Audit controls\n\n- THY-055 Functional security: roles, organizational levels and segregation of duties (Theory, 3 h)\n- IMPL-003 Authorization failure analysis and role requirement (Implementation, 2 h)\n\n### MOD-42 Configuration Project: Global Manufacturing Pvt Ltd\n\nTopics: Company; Company code; Chart of accounts; Fiscal year; Posting period; Currency; Document types; Number ranges; Tax; AP; AR; Assets; Banks; CO; Cost centers; Profit centers\n\n- PROJECT-003 Configuration project part 1: enterprise structure and general ledger (Project, 10 h)\n- PROJECT-004 Configuration project part 2: tax, payables, receivables, banks and assets (Project, 10 h)\n- PROJECT-005 Configuration project part 3: controlling, cost centres and profit centres (Project, 8 h)\n- ASM-027 Phase 27 assessment: implementation (Assessment, 3 h)\n\n## Phase 28 - Production Support\n\n### MOD-43 Production Support\n\nTopics: Incident management; Problem management; Change management; Root cause analysis; SLA; Priority; Severity; Functional analysis; Ticket lifecycle\n\n- THY-056 Support processes: incident, problem, change, priority and SLA (Theory, 3 h)\n- LAB-049 Production Support (Lab, 4 h)\n- SUP-001 Support ticket exercises: ten tickets (Support, 6 h)\n- DOC-007 Root cause analysis report and support runbook (Documentation, 4 h)\n\n### MOD-44 Troubleshooting\n\nTopics: Posting period closed; Account cannot be posted; Missing tax code; Incorrect reconciliation account; Vendor invoice error; Customer payment issue; Automatic payment failure; Asset depreciation error; GR/IR issue; Cost center error; Profit center error; Document splitting error; Currency issue; Exchange rate issue; Account determination error; Configuration transport issue\n\n- THY-057 Troubleshooting method and the eight-section report (Theory, 2 h)\n- TSH-043 Scenario 43: configuration transport issue, setting missing in the target system (Troubleshooting, 2 h)\n- TSH-044 Scenario 44: document posts in the wrong period or year (Troubleshooting, 1 h)\n- TSH-045 Scenario 45: cash discount posts to an unexpected account (Troubleshooting, 1 h)\n- TSH-046 Scenario 46: clearing creates an exchange rate difference (Troubleshooting, 2 h)\n- TSH-047 Scenario 47: recurring entry program does not post (Troubleshooting, 1 h)\n- TSH-048 Scenario 48: user cannot post above an amount (Troubleshooting, 1 h)\n- TSH-049 Scenario 49: balance sheet does not balance by profit centre (Troubleshooting, 2 h)\n- TSH-050 Scenario 50: depreciation posted but cost centre report is empty (Troubleshooting, 1 h)\n- TSH-051 Scenario 51: payment run posts but no payment file is created (Troubleshooting, 2 h)\n- TSH-052 Scenario 52: financial statement shows unassigned accounts (Troubleshooting, 1 h)\n- TSH-053 Scenario 53: month-end multi-fault case (Troubleshooting, 4 h)\n- ASM-028 Troubleshooting assessment (Assessment, 3 h)\n\n## Phase 29 - Advanced Consulting\n\n### MOD-45 End-to-End Business Scenarios\n\nTopics: Procure to Pay; Order to Cash; Record to Report; Asset Lifecycle; Financial Closing; Cost Center Accounting; Profit Center Accounting; Product Costing; Profitability Analysis; FI and CO impact at every step\n\n- SCN-001 Scenario 1: Procure to Pay (Scenario, 5 h)\n- SCN-002 Scenario 2: Order to Cash (Scenario, 5 h)\n- SCN-003 Scenario 3: Record to Report (Scenario, 5 h)\n- SCN-004 Scenario 4: Asset Lifecycle (Scenario, 4 h)\n- SCN-005 Scenario 5: Financial Closing (Scenario, 4 h)\n- SCN-006 Scenario 6: Cost Center Accounting (Scenario, 3 h)\n- SCN-007 Scenario 7: Profit Center Accounting (Scenario, 3 h)\n- SCN-008 Scenario 8: Product Costing (Scenario, 4 h)\n- SCN-009 Scenario 9: Profitability Analysis (Scenario, 3 h)\n\n### MOD-46 Transaction Code Curriculum\n\nTopics: General: SPRO, SE16N, SE38, SU01, PFCG, ST22, SM37, SM21, STMS; FI: General Ledger, AP, AR, Asset, Bank, Closing; CO: Cost Center, Internal Order, Profit Center, Product Costing, CO-PA; For each: purpose, when used, input, output, business scenario, common errors\n\n- DOC-008 Transaction reference: general and FI (Documentation, 5 h)\n- DOC-009 Transaction reference: CO and integration (Documentation, 4 h)\n\n### MOD-47 Master Data Reference\n\nTopics: FI: G/L, Customer, Vendor, Bank, Asset; CO: Cost center, Profit center, Internal order, Activity type, Statistical key figure; For each: purpose, structure, creation, change, display, integration, common errors\n\n- DOC-010 Master data reference for FI and CO (Documentation, 5 h)\n\n### MOD-48 Solution Design and Finance Architecture\n\nTopics: Central Finance concepts; Group Reporting concepts; SAP S/4HANA migration; Finance architecture; Advanced configuration; Solution design\n\n- THY-058 Central Finance and Group Reporting concepts (Theory, 3 h)\n- IMPL-004 Solution design for a multi-country rollout (Implementation, 6 h)\n- IMPL-005 Validations, substitutions and advanced configuration (Implementation, 3 h)\n\n### MOD-49 Interview Preparation\n\nTopics: Basic, intermediate, advanced, scenario-based, configuration, integration, troubleshooting and S/4HANA questions; Senior consultant: architecture, solution design, fit-gap, integration, migration, cutover, production support, RCA, client handling; Resume preparation; Project explanation\n\n- DOC-011 Interview bank: basic and intermediate (Documentation, 4 h)\n- DOC-012 Interview bank: advanced, configuration, integration and S/4HANA (Documentation, 4 h)\n- DOC-013 Interview bank: scenario-based and senior consultant (Documentation, 4 h)\n- DOC-014 Resume and project explanation (Documentation, 3 h)\n- ASM-029 Mock interviews: functional, configuration and client (Assessment, 3 h)\n\n## Phase 30 - Final Capstone\n\n### MOD-50 Capstone: Implement a Complete SAP FICO Solution for Global Manufacturing Corporation\n\nTopics: FI: company code, GL, AP, AR, asset, bank, tax, closing; CO: cost centers, profit centers, internal orders, product costing, CO-PA; Integration: MM, SD, AA; S/4HANA: Business Partner, Universal Journal, Fiori, New Asset Accounting; Processes: Procure to Pay, Order to Cash, Record to Report, Asset Lifecycle, Financial Closing, Management Accounting\n\n- CAP-001 Business requirements and organizational structure (Capstone, 6 h)\n- CAP-002 Master-data design and business-process document (Capstone, 6 h)\n- CAP-003 FI configuration (Capstone, 12 h)\n- CAP-004 CO configuration (Capstone, 10 h)\n- CAP-005 Integration configuration and S/4HANA settings (Capstone, 8 h)\n- CAP-006 Configuration document (Capstone, 5 h)\n- CAP-007 Test scripts, unit testing and integration testing (Capstone, 8 h)\n- CAP-008 User acceptance testing (Capstone, 4 h)\n- CAP-009 Execute the business processes: P2P, O2C, R2R, asset lifecycle, closing and management accounting (Capstone, 10 h)\n- CAP-010 Migration plan, cutover plan and go-live checklist (Capstone, 6 h)\n- CAP-011 Support runbook and troubleshooting guide (Capstone, 4 h)\n- CAP-012 Final project documentation and executive presentation (Capstone, 5 h)\n- ASM-030 Final assessment (Assessment, 3 h)\n",
   "parent": "Wiki"
  }
 ]
}
