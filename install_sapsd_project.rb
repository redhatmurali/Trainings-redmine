# SAP SD Complete Training Basic to Expert - one-shot Redmine installer
#
# Put this file and sapsd_issues.csv in the same folder. Run on the Redmine server,
# from the Redmine root directory, as the Redmine OS user:
#
#   STUDENTS=alice,bob INSTRUCTORS=admin \
#     bundle exec rails runner -e production /path/to/install_sapsd_project.rb
#
# Environment variables (all optional):
#   CSV            path to sapsd_issues.csv (default: same folder as this script)
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
csv_path   = File.join(course_dir, 'sapsd_issues.csv') if csv_path.empty?
halt("not found: #{csv_path} (set CSV=/path/to/sapsd_issues.csv)") unless File.file?(csv_path)

# The project definition (fields, queries, wiki pages) is embedded at the end of this file.
embedded = File.read(File.expand_path(__FILE__), :encoding => 'utf-8').split("\n__END__\n", 2)[1]
halt('embedded project definition missing from this script') if embedded.to_s.strip.empty?
course = JSON.parse(embedded)
$tag   = course['tag'].to_s.empty? ? 'course' : course['tag']
rows   = CSV.read(csv_path, :headers => true, :encoding => 'bom|utf-8').map(&:to_h)
halt('sapsd_issues.csv is empty') if rows.empty?
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
 "tag": "sapsd",
 "project": {
  "name": "SAP SD — Complete Training Basic to Expert",
  "identifier": "sap-sd-complete-basic-to-expert",
  "description": "SAP Sales and Distribution programme from sales beginner to SAP SD / S/4HANA Sales consultant: business sales, master data, sales, pricing, availability, shipping, delivery, billing, credit, output, FI/MM/CO integration, S/4HANA, testing, migration, implementation and support, across 30 phases ending in a full implementation capstone. Every topic follows Concept -> Business Scenario -> Configuration -> Transaction/Fiori -> Document Flow -> Logistics/Accounting Impact -> Testing -> Troubleshooting -> Documentation -> Assessment. One shared project; every student has a personal copy of each issue."
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
   "name": "Sales Fundamentals",
   "kind": "work"
  },
  {
   "name": "Configuration",
   "kind": "work"
  },
  {
   "name": "Master Data",
   "kind": "work"
  },
  {
   "name": "Sales Process",
   "kind": "work"
  },
  {
   "name": "Shipping",
   "kind": "work"
  },
  {
   "name": "Billing",
   "kind": "work"
  },
  {
   "name": "Pricing",
   "kind": "work"
  },
  {
   "name": "Integration",
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
  "Troubleshooting",
  "Documentation",
  "Testing",
  "Review",
  "Business Process",
  "Master Data"
 ],
 "versions": [
  "V01.0 Sales & Distribution Fundamentals",
  "V02.0 SAP Fundamentals",
  "V03.0 SAP SD Navigation",
  "V04.0 Enterprise Structure",
  "V05.0 SD Master Data",
  "V06.0 Sales Documents",
  "V07.0 Sales Order Processing",
  "V08.0 Pricing",
  "V09.0 Availability & ATP",
  "V10.0 Shipping",
  "V11.0 Delivery",
  "V12.0 Picking & Packing",
  "V13.0 PGI",
  "V14.0 Billing",
  "V15.0 Credit Management",
  "V16.0 Output Management",
  "V17.0 Special Sales Processes",
  "V18.0 FI Integration",
  "V19.0 MM Integration",
  "V20.0 CO Integration",
  "V21.0 S/4HANA Sales",
  "V22.0 Fiori",
  "V23.0 Advanced ATP",
  "V24.0 Advanced Pricing",
  "V25.0 Testing",
  "V26.0 Migration",
  "V27.0 Implementation",
  "V28.0 Production Support",
  "V29.0 Advanced Consulting",
  "V30.0 Enterprise Capstone"
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
   "name": "Fiori App",
   "format": "list",
   "multiple": true,
   "trackers": "all",
   "csv": "Fiori App",
   "sort": true
  },
  {
   "name": "Configuration Area",
   "format": "list",
   "trackers": "all",
   "csv": "Configuration Area"
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
    "Order to Cash",
    "Contracts",
    "Credit Management",
    "Returns",
    "Third-Party",
    "Make-to-Order",
    "Consignment"
   ],
   "csv": "Business Process"
  },
  {
   "name": "Integration Module",
   "format": "list",
   "trackers": "all",
   "values": [
    "None",
    "FI",
    "MM",
    "CO",
    "Logistics"
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
    "Business",
    "SD",
    "Integration",
    "S/4HANA",
    "Consultant"
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
      "tracker:Lab+Configuration+Master Data+Sales Process+Shipping+Billing+Pricing+Integration+Scenario"
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
   "name": "Dashboard: Business skills",
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
      "Business"
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
   "name": "Dashboard: SD skills",
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
      "SD"
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
   "name": "Dashboard: Integration skills",
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
      "Integration"
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
   "name": "Dashboard: by integration module",
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
     "cf:Integration Module",
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
   "group_by": "cf:Integration Module",
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
   "name": "Dashboard: configuration",
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
      "tracker:Configuration"
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
      "tracker:Assessment+Project+Capstone+Scenario"
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
   "text": "# SAP SD - Complete Training Basic to Expert\n\nSAP Sales and Distribution programme from sales beginner to SAP SD / S/4HANA Sales consultant: business sales, master data, sales, pricing, availability, shipping, delivery, billing, credit, output, FI/MM/CO integration, S/4HANA, testing, migration, implementation and support, across 30 phases ending in a full implementation capstone. Every topic follows Concept -> Business Scenario -> Configuration -> Transaction/Fiori -> Document Flow -> Logistics/Accounting Impact -> Testing -> Troubleshooting -> Documentation -> Assessment. One shared project; every student has a personal copy of each issue.\n\n## How to work an issue\n\n1. Open your next issue from the saved query *My next tasks*.\n2. Set the status to **In Progress** and do the steps. Log time at the end of every session.\n3. Set **Testing**, check every acceptance criterion, attach the evidence.\n4. Set **Review**. The instructor sets **Completed** or **Reopened**.\n\n## Pages\n\n- [[Training_System]]\n- [[Course_Company]]\n- [[Order_to_Cash_Flow]]\n- [[Month_End_Sales_Closing]]\n- [[Document_Templates]]\n- [[Troubleshooting_Report]]\n- [[Workflow_and_Statuses]]\n- [[Assessment_and_Grading]]\n- [[Evidence_Standards]]\n- [[Dashboard_Guide]]\n- [[Skill_Matrix]]\n- [[Transaction_Code_Index]]\n- [[Fiori_App_Index]]\n- [[Module_Index]]"
  },
  {
   "title": "Training_System",
   "text": "# Training system\n\nPhase 1 needs only the sales workbook. From phase 2 every student needs a user on an SAP S/4HANA training or practice system with configuration rights in a training client, plus the Fiori launchpad. The instructor provides the system, the workbook, the legacy data files for migration, initial stock, the client briefs and the prepared error cases for the troubleshooting scenarios.\n\nTransaction codes in the issues are SAP GUI codes; some differ by release or have been replaced by Fiori apps in S/4HANA. Fiori app names also change between releases: check the apps reference library for your release. Advanced ATP (phase 23) needs its own licence and activation; where the training system does not have it, the labs are done as documented walkthroughs.",
   "parent": "Wiki"
  },
  {
   "title": "Course_Company",
   "text": "# Course company\n\n**Global Manufacturing Corporation** is the fictional company of the labs, the implementation project and the capstone.\n\n| Item | Design |\n|---|---|\n| Business | Manufacturer of industrial components, sells to distributors, direct customers and export customers |\n| Company code | One company code for the labs; further countries in the enterprise project |\n| Sales organizations | One domestic sales organization for the labs; one per country in the enterprise project |\n| Distribution channels | Direct sales and distributors |\n| Divisions | Two product divisions |\n| Plants and shipping points | One manufacturing plant and one distribution centre, each with a shipping point |\n| Pricing | List price by material, customer and price group discounts, quantity scales, freight, tax |\n| Credit | Credit limits by customer with automatic check at order and delivery |\n| Special processes | Returns, third-party, make-to-order, consignment, contracts |",
   "parent": "Wiki"
  },
  {
   "title": "Order_to_Cash_Flow",
   "text": "# Order-to-Cash flow\n\n| Step | Document | Typical transaction | Logistics impact | Accounting impact |\n|---|---|---|---|---|\n| Inquiry | Inquiry | VA11 | None | None |\n| Quotation | Quotation | VA21 | None | None |\n| Sales order | Order with schedule lines | VA01 | Requirement passed to planning; stock reserved by confirmation | None (credit exposure rises) |\n| Availability check | Confirmed schedule lines | CO09 | Confirmed quantity | None |\n| Delivery | Outbound delivery | VL01N | Delivery requirement replaces order requirement | None |\n| Picking | Picking or warehouse task | VL02N | Picked quantity | None |\n| Packing | Handling units | VL02N | Packed quantity | None |\n| Post goods issue | Material document | VL02N | Stock reduced | Cost of goods sold debit, inventory credit |\n| Billing | Invoice | VF01 | None | Customer debit, revenue and tax credit |\n| Incoming payment | Payment document | F-28 | None | Bank debit, customer credit; exposure falls |",
   "parent": "Wiki"
  },
  {
   "title": "Month_End_Sales_Closing",
   "text": "# Month-end sales closing checklist\n\n| Step | Activity | Typical transaction |\n|---|---|---|\n| 1 | Open deliveries: goods issue for everything shipped | VL06O, VL10 |\n| 2 | Billing completion: process the billing due list | VF04 |\n| 3 | Billing blocks: review and release | V.23 |\n| 4 | Credit blocks: review blocked documents | VKM1 or UKM_MY_DCDS |\n| 5 | Returns: complete open returns and credit memos | VA05, VF04 |\n| 6 | Invoices not released to accounting | VFX3 |\n| 7 | Backorders and incomplete documents | V.15, V.02 |\n| 8 | Billing reconciliation: billed value against revenue accounts | VF05, FAGLB03 |\n| 9 | Receivables reconciliation | FBL5N |\n| 10 | Revenue reporting by sales area, customer and product | MCTA, KE30 |",
   "parent": "Wiki"
  },
  {
   "title": "Document_Templates",
   "text": "# Document templates\n\n**Business requirement document:** numbered requirements; priority; owner; acceptance.\n\n**Fit-gap analysis:** requirement; standard fit; gap; options; decision; effort.\n\n**Business process document:** scope; roles; steps; documents; controls; exceptions.\n\n**Configuration document:** area; IMG path or app; setting and values; business reason; unit test reference.\n\n**Functional specification:** purpose; process context; logic; selection; output; authorization; error handling; test cases.\n\n**Test script:** id; objective; preconditions; steps; test data; expected result; expected document flow; expected accounting and logistics impact; actual result; evidence; status.\n\n**Test evidence:** script id; document numbers; screenshots; tester; date; result.\n\n**Data migration plan:** object; source; cleansing; mapping; tool; sequence; validation; sign-off.\n\n**Cutover plan:** task; owner; start; duration; dependency; verification; fallback.\n\n**Go-live checklist:** readiness item; owner; evidence; go or no-go.\n\n**Support runbook:** process; schedule; checks; known errors; contacts; escalation.\n\n**Root cause analysis:** incident; timeline; impact; root cause; corrective action; preventive action.\n\n**User training material:** purpose; steps with screens; common errors; who to contact.",
   "parent": "Wiki"
  },
  {
   "title": "Troubleshooting_Report",
   "text": "# Troubleshooting report\n\nEvery troubleshooting issue is closed with these eight sections:\n\n1. **Problem** - the message number and text and what the user was doing\n2. **Business impact** - what cannot be done and who is affected\n3. **Evidence** - screenshots, document numbers, logs and settings seen\n4. **Root cause** - the configuration or master data behind the error\n5. **Configuration** - where the setting lives\n6. **Fix** - the change made\n7. **Validation** - the original transaction now works\n8. **Prevention** - what stops it happening again\n\nAnalysis tools: document flow, status overview, incompletion log, pricing analysis, availability overview, output log, billing log, credit decision.",
   "parent": "Wiki"
  },
  {
   "title": "Workflow_and_Statuses",
   "text": "# Workflow and statuses\n\n| Status | Meaning |\n|---|---|\n| New | Template or unassigned |\n| Assigned | Belongs to a student, not started |\n| In Progress | Being worked on |\n| Blocked | Cannot continue; a note states the blocker |\n| Testing | Steps done; student checks the acceptance criteria and collects evidence |\n| Review | Submitted to the instructor |\n| Completed | Approved by the instructor |\n| Reopened | Changes requested |\n| Rejected | Waived or not applicable (instructor only) |\n\nPrerequisites are *blocked by* relations: an issue cannot be closed while its blocker is open.",
   "parent": "Wiki"
  },
  {
   "title": "Assessment_and_Grading",
   "text": "# Assessment and grading\n\n| Type | Covers |\n|---|---|\n| Business assessments | Sales process questions, O2C scenarios, logistics scenarios |\n| SAP assessments | Configuration, master data, transactions, Fiori |\n| Consultant assessments | Requirement analysis, solution design, configuration decisions, integration |\n| Scenario assessments | Understand requirement; identify SAP process; identify configuration; execute transaction or Fiori app; validate document flow; validate accounting/logistics impact; document solution |\n| Projects and capstone | Master data, end-to-end O2C, advanced pricing, implementation, enterprise project and the capstone, each scored 0-100 |\n\nPass mark 70. Programme grade: phase assessments 30 %, projects and scenarios 30 %, capstone 40 %. A student is not complete by finishing theory: every phase gate requires its labs and troubleshooting cases, and the programme requires testing, migration, the implementation project, production support and the capstone.",
   "parent": "Wiki"
  },
  {
   "title": "Evidence_Standards",
   "text": "# Evidence standards\n\n| Evidence | Minimum content |\n|---|---|\n| Notes | Own words, one page, diagrams where useful |\n| Worked solution | Calculations or document sets with workings, checked against the workbook |\n| Document numbers + screenshots | Sales area, document number and a screenshot of the result |\n| Configuration document entry | Area, path, values, business reason and test document number |\n| Process document + document numbers | Each step with its document number, document flow and stock or accounting impact |\n| Test script + evidence | Script in the template with actual results and evidence per step |\n| Root cause report | The eight sections |\n| Ticket notes | Analysis, solution, user communication, closure |\n| Written deliverable | Document in the course template |\n| Project documentation | All project documents plus test evidence |\n| Scored result | Score and feedback recorded by the instructor |",
   "parent": "Wiki"
  },
  {
   "title": "Dashboard_Guide",
   "text": "# Dashboard guide\n\nThe dashboard is the set of saved queries in the issue list sidebar. Add them to *My page* as custom query blocks.\n\n| Section | Saved query |\n|---|---|\n| Course progress | Dashboard: overall completion; phase completion; module completion; labs completed; assessment completion |\n| SD skills | Dashboard: SD skills (grouped by category: Master Data, Sales, Pricing, Availability, Shipping, Delivery, Billing, Credit, Output, Special Processes) |\n| Integration skills | Dashboard: Integration skills (FI, MM, CO); Dashboard: by integration module adds Logistics |\n| S/4HANA skills | Dashboard: S/4HANA skills (S/4HANA, Fiori, Advanced ATP, Reporting); Business Partner, Credit Management and Output Management are under SD skills, filter S/4HANA Relevance = Changed/New |\n| Consultant skills | Dashboard: Consultant skills (Testing, Migration, Implementation, Cutover and Go-Live, Production Support, Troubleshooting, ...) |\n| Business | Dashboard: Business skills |\n\nPicking, packing and goods issue are tasks inside the Delivery category; use *Dashboard: phase completion* (phases 12 and 13) for them.\n\nFor % done to follow the status, set *Administration > Settings > Issue tracking > Calculate the issue done ratio* to *Use the issue status* (global setting).",
   "parent": "Wiki"
  },
  {
   "title": "Skill_Matrix",
   "text": "# Skill matrix\n\n| Area | Track | Level | Modules | Tasks | Hours |\n|---|---|---|---|---|---|\n| Sales Fundamentals | Business | Level 1 - Sales & SAP Foundation | MOD-01, MOD-02 | 7 | 18 |\n| SAP Basics | Consultant | Level 1 - Sales & SAP Foundation | MOD-03, MOD-04 | 10 | 22 |\n| Enterprise Structure | SD | Level 2 - SAP SD Core | MOD-05 | 13 | 23 |\n| Master Data | SD | Level 2 - SAP SD Core | MOD-06, MOD-07, MOD-08 | 15 | 37 |\n| Sales | SD | Level 2 - SAP SD Core | MOD-09, MOD-10, MOD-11, MOD-12, MOD-13 | 23 | 56 |\n| Sales | SD | Level 3 - Advanced SD & Integration | MOD-14 | 6 | 15 |\n| Pricing | SD | Level 2 - SAP SD Core | MOD-15 | 14 | 37 |\n| Availability | SD | Level 2 - SAP SD Core | MOD-16 | 7 | 16 |\n| Shipping | SD | Level 2 - SAP SD Core | MOD-17 | 9 | 19 |\n| Delivery | SD | Level 2 - SAP SD Core | MOD-18, MOD-20, MOD-21, MOD-22 | 20 | 38 |\n| Delivery | SD | Level 3 - Advanced SD & Integration | MOD-19 | 6 | 11 |\n| Billing | SD | Level 2 - SAP SD Core | MOD-23, MOD-24 | 12 | 27 |\n| Credit | SD | Level 3 - Advanced SD & Integration | MOD-25 | 6 | 15 |\n| Output | SD | Level 3 - Advanced SD & Integration | MOD-26 | 8 | 20 |\n| Special Processes | SD | Level 3 - Advanced SD & Integration | MOD-27, MOD-28, MOD-29, MOD-30 | 18 | 42 |\n| FI Integration | Integration | Level 3 - Advanced SD & Integration | MOD-31, MOD-32 | 9 | 22 |\n| MM Integration | Integration | Level 3 - Advanced SD & Integration | MOD-33 | 5 | 13 |\n| CO Integration | Integration | Level 3 - Advanced SD & Integration | MOD-34 | 3 | 7 |\n| S/4HANA | S/4HANA | Level 4 - S/4HANA Sales Expert | MOD-35 | 6 | 16 |\n| Fiori | S/4HANA | Level 4 - S/4HANA Sales Expert | MOD-36 | 3 | 8 |\n| Reporting | S/4HANA | Level 3 - Advanced SD & Integration | MOD-37 | 3 | 8 |\n| Advanced ATP | S/4HANA | Level 4 - S/4HANA Sales Expert | MOD-38 | 11 | 27 |\n| Pricing | SD | Level 3 - Advanced SD & Integration | MOD-39, MOD-40 | 14 | 43 |\n| Testing | Consultant | Level 3 - Advanced SD & Integration | MOD-41 | 9 | 31 |\n| Migration | Consultant | Level 3 - Advanced SD & Integration | MOD-42 | 10 | 26 |\n| Implementation | Consultant | Level 3 - Advanced SD & Integration | MOD-43, MOD-44, MOD-46, MOD-48 | 14 | 64 |\n| Cutover and Go-Live | Consultant | Level 3 - Advanced SD & Integration | MOD-45 | 2 | 6 |\n| Implementation | Integration | Level 3 - Advanced SD & Integration | MOD-47 | 3 | 10 |\n| Production Support | Consultant | Level 3 - Advanced SD & Integration | MOD-49 | 4 | 17 |\n| Troubleshooting | Consultant | Level 3 - Advanced SD & Integration | MOD-50 | 13 | 22 |\n| Business Scenarios | Consultant | Level 3 - Advanced SD & Integration | MOD-51, MOD-52, MOD-54 | 13 | 50 |\n| Business Scenarios | Consultant | Level 4 - S/4HANA Sales Expert | MOD-53, MOD-55 | 4 | 27 |\n| Career | Consultant | Level 3 - Advanced SD & Integration | MOD-56 | 5 | 17 |\n| Capstone | Consultant | Level 4 - S/4HANA Sales Expert | MOD-57 | 12 | 83 |",
   "parent": "Wiki"
  },
  {
   "title": "Transaction_Code_Index",
   "text": "# Transaction code index\n\nGrouped by where each code is used. The seven-part reference (purpose, business scenario, input, output, related configuration, common errors, Fiori app) is written by the student in the transaction reference tasks of phase 29.\n\n| Transaction | Modules |\n|---|---|\n| /UI2/FLP | MOD-36 |\n| 0184 | MOD-18 |\n| 0VLK | MOD-18 |\n| 0VLP | MOD-18 |\n| 0VTC | MOD-17 |\n| BP | MOD-06, MOD-35, MOD-42, MOD-52, MOD-57 |\n| BUC2 | MOD-06 |\n| BUCF | MOD-06 |\n| CO06 | MOD-16, MOD-38 |\n| CO09 | MOD-16, MOD-38, MOD-52 |\n| EC01 | MOD-05 |\n| F-28 | MOD-31, MOD-51, MOD-52 |\n| FAGLB03 | MOD-47 |\n| FB03 | MOD-22, MOD-31, MOD-51, MOD-52 |\n| FBL5N | MOD-31, MOD-47 |\n| FD32 | MOD-25 |\n| FTXP | MOD-32 |\n| HU03 | MOD-21 |\n| IQ03 | MOD-19 |\n| KE24 | MOD-34 |\n| KE30 | MOD-34 |\n| KE4I | MOD-34 |\n| LSMW | MOD-42 |\n| LT03 | MOD-20, MOD-52 |\n| LTMC | MOD-42 |\n| LTMOM | MOD-42 |\n| MB03 | MOD-22 |\n| MB1C | MOD-30 |\n| MB51 | MOD-33 |\n| MCTA | MOD-37 |\n| MCTC | MOD-37 |\n| MD04 | MOD-16, MOD-30, MOD-33, MOD-38 |\n| ME21N | MOD-29, MOD-33 |\n| ME52N | MOD-29 |\n| ME57 | MOD-29 |\n| MIGO | MOD-07, MOD-29, MOD-30, MOD-33 |\n| MIRO | MOD-29 |\n| MM01 | MOD-07 |\n| MM02 | MOD-07 |\n| MM03 | MOD-07, MOD-42 |\n| MMBE | MOD-07, MOD-22, MOD-28, MOD-30, MOD-33, MOD-51 |\n| MSC1N | MOD-19 |\n| NACE | MOD-26, MOD-50 |\n| OBYC | MOD-31, MOD-33 |\n| OPD | MOD-26, MOD-35 |\n| OV02 | MOD-14 |\n| OV12 | MOD-14 |\n| OV31 | MOD-39 |\n| OV32 | MOD-39 |\n| OVA2 | MOD-11 |\n| OVA8 | MOD-25 |\n| OVAD | MOD-25 |\n| OVAK | MOD-25 |\n| OVAZ | MOD-11 |\n| OVK1 | MOD-32, MOD-53 |\n| OVK3 | MOD-32 |\n| OVK4 | MOD-32 |\n| OVK5 | MOD-24 |\n| OVK6 | MOD-24, MOD-32 |\n| OVKI | MOD-15 |\n| OVKK | MOD-15, MOD-39, MOD-40 |\n| OVKP | MOD-15 |\n| OVL2 | MOD-17 |\n| OVL3 | MOD-17, MOD-20 |\n| OVLG | MOD-17 |\n| OVLN | MOD-17 |\n| OVLZ | MOD-17 |\n| OVSZ | MOD-17 |\n| OVX1 | MOD-05 |\n| OVX3 | MOD-05 |\n| OVX4 | MOD-05 |\n| OVX5 | MOD-05 |\n| OVX6 | MOD-05 |\n| OVXA | MOD-05 |\n| OVXB | MOD-05 |\n| OVXC | MOD-05 |\n| OVXD | MOD-05 |\n| OVXG | MOD-05 |\n| OVXI | MOD-05 |\n| OVXJ | MOD-05 |\n| OVXK | MOD-05 |\n| OVXM | MOD-05 |\n| OVZ2 | MOD-16 |\n| OVZ9 | MOD-16 |\n| OVZG | MOD-16 |\n| OVZH | MOD-16 |\n| OVZI | MOD-16 |\n| OX02 | MOD-05 |\n| OX09 | MOD-05 |\n| OX10 | MOD-05 |\n| OX15 | MOD-05 |\n| PFCG | MOD-03, MOD-46, MOD-54 |\n| POP1 | MOD-21 |\n| SE10 | MOD-43, MOD-50 |\n| SE16N | MOD-04, MOD-35, MOD-41, MOD-42, MOD-49, MOD-54 |\n| SE38 | MOD-54 |\n| SM21 | MOD-49, MOD-54 |\n| SM37 | MOD-49, MOD-54 |\n| SP01 | MOD-26 |\n| SPRO | MOD-03, MOD-43, MOD-45, MOD-48, MOD-53, MOD-54, MOD-55, MOD-57 |\n| ST22 | MOD-49, MOD-54 |\n| STMS | MOD-03, MOD-43, MOD-45, MOD-49, MOD-50, MOD-54 |\n| SU01 | MOD-03, MOD-46, MOD-54 |\n| SU3 | MOD-04 |\n| SU53 | MOD-46, MOD-49 |\n| SUIM | MOD-46 |\n| UKM_BP | MOD-25, MOD-35 |\n| UKM_MALUS_DSP | MOD-25 |\n| UKM_MY_DCDS | MOD-47 |\n| V.02 | MOD-11 |\n| V.15 | MOD-16, MOD-37, MOD-47 |\n| V.23 | MOD-23, MOD-37, MOD-47 |\n| V/03 | MOD-15 |\n| V/06 | MOD-15, MOD-39, MOD-40 |\n| V/07 | MOD-15, MOD-39, MOD-40 |\n| V/08 | MOD-15, MOD-39, MOD-40, MOD-50 |\n| V/30 | MOD-26 |\n| V/43 | MOD-26 |\n| V/C7 | MOD-19 |\n| V/C8 | MOD-19 |\n| V/LD | MOD-39 |\n| V_RA | MOD-38 |\n| V_UC | MOD-37 |\n| V_V2 | MOD-16 |\n| VA01 | MOD-09, MOD-10, MOD-15, MOD-16, MOD-23, MOD-25, MOD-27, MOD-28, MOD-29, MOD-30, MOD-38, MOD-40, MOD-41, MOD-51, MOD-52, MOD-53, MOD-57 |\n| VA02 | MOD-09, MOD-23, MOD-38, MOD-50 |\n| VA03 | MOD-04, MOD-09, MOD-34, MOD-41, MOD-49, MOD-51 |\n| VA05 | MOD-09, MOD-37, MOD-42, MOD-45, MOD-47 |\n| VA11 | MOD-09, MOD-52 |\n| VA21 | MOD-09, MOD-52 |\n| VA31 | MOD-10 |\n| VA32 | MOD-10 |\n| VA41 | MOD-10 |\n| VA42 | MOD-10 |\n| VA43 | MOD-10 |\n| VA45 | MOD-10 |\n| VB01 | MOD-14 |\n| VB11 | MOD-14 |\n| VB21 | MOD-39 |\n| VB31 | MOD-39 |\n| VBN1 | MOD-39 |\n| VCH1 | MOD-18, MOD-19 |\n| VD03 | MOD-06 |\n| VD51 | MOD-08 |\n| VD52 | MOD-08 |\n| VD53 | MOD-42 |\n| VF01 | MOD-23, MOD-27, MOD-28, MOD-29, MOD-30, MOD-40, MOD-41, MOD-51, MOD-52, MOD-53, MOD-57 |\n| VF02 | MOD-23, MOD-50 |\n| VF03 | MOD-04, MOD-23, MOD-31, MOD-34, MOD-39 |\n| VF04 | MOD-23, MOD-45, MOD-47 |\n| VF05 | MOD-23, MOD-37, MOD-47 |\n| VF11 | MOD-23 |\n| VF31 | MOD-26 |\n| VFX3 | MOD-23, MOD-31, MOD-47, MOD-50 |\n| VHAR | MOD-21 |\n| VHZU | MOD-21 |\n| VK11 | MOD-15, MOD-32, MOD-39, MOD-40, MOD-42, MOD-53, MOD-57 |\n| VK12 | MOD-15, MOD-39 |\n| VK13 | MOD-15, MOD-39, MOD-42 |\n| VK31 | MOD-39 |\n| VKM1 | MOD-25, MOD-47, MOD-50 |\n| VKM3 | MOD-25 |\n| VKM4 | MOD-25 |\n| VKOA | MOD-24, MOD-31 |\n| VL01N | MOD-18, MOD-28, MOD-29, MOD-30, MOD-33, MOD-41, MOD-51, MOD-52, MOD-57 |\n| VL02N | MOD-18, MOD-20, MOD-21, MOD-22, MOD-27, MOD-28, MOD-50, MOD-51, MOD-52 |\n| VL03N | MOD-04, MOD-18 |\n| VL06G | MOD-22 |\n| VL06O | MOD-18, MOD-37, MOD-42, MOD-45, MOD-47 |\n| VL06P | MOD-20 |\n| VL09 | MOD-22 |\n| VL10 | MOD-47 |\n| VL10A | MOD-10, MOD-18 |\n| VN01 | MOD-11, MOD-24 |\n| VOFA | MOD-24 |\n| VOFM | MOD-39 |\n| VOPAN | MOD-08 |\n| VOTXN | MOD-14 |\n| VOV4 | MOD-12 |\n| VOV5 | MOD-12 |\n| VOV6 | MOD-12 |\n| VOV7 | MOD-12 |\n| VOV8 | MOD-11, MOD-27 |\n| VTAA | MOD-13 |\n| VTAF | MOD-13 |\n| VTFA | MOD-13, MOD-24 |\n| VTFL | MOD-13, MOD-24, MOD-39, MOD-50 |\n| VTLA | MOD-13, MOD-50 |\n| VUA2 | MOD-11 |\n| VV11 | MOD-26 |\n| VV21 | MOD-26 |\n| VV31 | MOD-26 |\n| XD03 | MOD-06 |",
   "parent": "Wiki"
  },
  {
   "title": "Fiori_App_Index",
   "text": "# Fiori app index\n\nApp names as used in the issues; names and availability vary by release, so confirm in the apps reference library.\n\n| Fiori app | Modules |\n|---|---|\n| Assign Product to Product Allocation | MOD-38 |\n| Configure Alternative Control | MOD-38 |\n| Configure BOP Segment | MOD-38 |\n| Configure BOP Variant | MOD-38 |\n| Configure Product Allocation | MOD-38 |\n| Create Billing Documents | MOD-23, MOD-36, MOD-47 |\n| Create Outbound Deliveries | MOD-18, MOD-36 |\n| Customer - 360 View | MOD-06, MOD-36 |\n| Display Credit Exposure | MOD-25 |\n| Incoming Sales Orders | MOD-37 |\n| Manage Billing Documents | MOD-23 |\n| Manage Business Partner Master Data | MOD-06 |\n| Manage Credit Accounts | MOD-25 |\n| Manage Credit Memo Requests | MOD-28 |\n| Manage Customer Returns | MOD-28 |\n| Manage Customer-Material Prices | MOD-39 |\n| Manage Debit Memo Requests | MOD-28 |\n| Manage Documented Credit Decisions | MOD-25, MOD-47 |\n| Manage Outbound Deliveries | MOD-18 |\n| Manage Prices - Sales | MOD-15, MOD-39 |\n| Manage Product Allocation Planning Data | MOD-38 |\n| Manage Product Master Data | MOD-07 |\n| Manage Sales Contracts | MOD-10 |\n| Manage Sales Inquiries | MOD-09 |\n| Manage Sales Orders | MOD-04, MOD-09, MOD-36 |\n| Manage Sales Quotations | MOD-09 |\n| Manage Sales Scheduling Agreements | MOD-10 |\n| Migrate Your Data - Migration Cockpit | MOD-42 |\n| Monitor BOP Run | MOD-38 |\n| My Sales Overview | MOD-04, MOD-36 |\n| Review Availability Check Results | MOD-38 |\n| Sales Management Overview | MOD-37 |\n| Sales Order Fulfillment Issues | MOD-36, MOD-47 |\n| Sales Volume - Check Open Sales | MOD-37 |\n| Schedule BOP Run | MOD-38 |\n| Set Material Prices - Sales | MOD-15, MOD-39 |\n| Track Sales Orders | MOD-09 |",
   "parent": "Wiki"
  },
  {
   "title": "Module_Index",
   "text": "# Module index\n\n## Phase 01 - Sales & Distribution Fundamentals\n\n### MOD-01 Business Sales Fundamentals\n\nTopics: What is sales; What is distribution; Customer; Prospect; Lead; Sales quotation; Sales order; Delivery; Shipment; Invoice; Payment; Returns; Credit memo; Debit memo; Discounts; Taxes; Freight; Commission\n\n- SALES-001 What sales and distribution are (Sales Fundamentals, 3 h)\n- SALES-002 Read real sales documents (Sales Fundamentals, 2 h)\n- SALES-003 Prices, discounts, tax and freight calculations (Sales Fundamentals, 3 h)\n\n### MOD-02 Order-to-Cash\n\nTopics: Customer; Inquiry; Quotation; Sales Order; Availability Check; Delivery; Picking; Packing; Post Goods Issue; Billing; Accounting; Incoming Payment; Business purpose and document flow at every stage; Customer lifecycle\n\n- SALES-004 The Order-to-Cash cycle and why each step exists (Sales Fundamentals, 3 h)\n- SALES-005 Order-to-Cash on paper: follow three orders (Sales Fundamentals, 3 h)\n- SALES-006 Logistics and accounting impact of a sale (Sales Fundamentals, 2 h)\n- ASM-001 Phase 01 assessment: sales fundamentals (Assessment, 2 h)\n\n## Phase 02 - SAP Fundamentals\n\n### MOD-03 SAP Fundamentals\n\nTopics: SAP ERP; SAP ECC; SAP S/4HANA; SAP GUI; SAP Fiori; SAP system; Client; User; Roles; Authorizations; Transport Management System; IMG; SPRO\n\n- THY-001 ERP, SAP ECC and SAP S/4HANA (Theory, 3 h)\n- THY-002 Systems, clients, transports and the IMG (Theory, 3 h)\n- THY-003 Users, roles and authorizations (Theory, 2 h)\n- LAB-031 Access the training system (Lab, 2 h)\n- ASM-002 Phase 02 assessment: SAP fundamentals (Assessment, 1 h)\n\n## Phase 03 - SAP SD Navigation\n\n### MOD-04 SAP SD Navigation\n\nTopics: SAP GUI; Easy Access menu; Transaction codes; Fiori Launchpad; Favorites; Sessions; Search; Help; SD menu structure; Working without memorizing transaction codes\n\n- LAB-032 SAP GUI: menu, command field, sessions and favourites (Lab, 3 h)\n- LAB-033 Display an existing order, delivery and invoice and their document flow (Lab, 3 h)\n- LAB-034 Fiori launchpad for sales (Lab, 3 h)\n- THY-004 The pattern of SD transaction codes (Theory, 1 h)\n- ASM-003 Phase 03 assessment: navigation practical (Assessment, 1 h)\n\n## Phase 04 - Enterprise Structure\n\n### MOD-05 SD Organizational Structure\n\nTopics: Client; Company; Company Code; Sales Organization; Distribution Channel; Division; Sales Area; Plant; Storage Location; Shipping Point; Loading Point; Sales Office; Sales Group; Sales Organization + Distribution Channel + Division = Sales Area\n\n- THY-005 Organizational units in sales and how they relate (Theory, 4 h)\n- THY-006 The course company: Global Manufacturing Corporation (Theory, 2 h)\n- CFG-001 Define company and company code (Configuration, 2 h)\n- LAB-001 Create Sales Organization (Lab, 2 h)\n- LAB-002 Configure Distribution Channel (Lab, 1 h)\n- LAB-003 Configure Division (Lab, 1 h)\n- LAB-004 Create Sales Area (Lab, 2 h)\n- LAB-005 Configure Plant (Lab, 2 h)\n- LAB-006 Configure Shipping Point (Lab, 2 h)\n- CFG-002 Sales offices and sales groups (Configuration, 1 h)\n- TSH-001 Scenario 01: sales area is not defined for the customer or document (Troubleshooting, 1 h)\n- TSH-002 Scenario 02: plant not assigned to the sales organization and channel (Troubleshooting, 1 h)\n- ASM-004 Phase 04 assessment: enterprise structure (Assessment, 2 h)\n\n## Phase 05 - SD Master Data\n\n### MOD-06 Business Partner and Customer Master\n\nTopics: Business Partner; BP roles; Customer role; General data; Company-code data; Sales-area data; Partner functions; Number ranges; Groupings; BP integration; Name; Address; Communication; Tax information; Reconciliation account; Payment terms; Dunning; Sales, shipping and billing data\n\n- THY-007 The business partner model and customer data levels (Theory, 3 h)\n- CFG-003 Business partner groupings and number ranges (Configuration, 2 h)\n- LAB-007 Create Business Partner (Lab, 3 h)\n- LAB-008 Create Customer Master (Lab, 3 h)\n- MD-001 Ship-to, bill-to and payer as separate partners (Master Data, 2 h)\n\n### MOD-07 Material Master for SD\n\nTopics: Basic data; Sales organization data; Sales data; Plant data; Accounting concepts; Loading group; Transportation group; Item category relevance; How material master affects sales and delivery\n\n- THY-008 Material views that drive sales and delivery (Theory, 3 h)\n- LAB-009 Create Material Master (Lab, 3 h)\n\n### MOD-08 Customer-Material Info and Partner Determination\n\nTopics: Customer-material info; Sold-to party; Ship-to party; Bill-to party; Payer; Partner functions; Partner procedures; Partner determination; Master data relationships\n\n- MD-002 Customer-material info record (Master Data, 2 h)\n- THY-009 Partner functions and partner determination procedures (Theory, 2 h)\n- CFG-004 Configure partner determination (Configuration, 3 h)\n- TSH-003 Scenario 03: customer master missing for the sales area (Troubleshooting, 1 h)\n- TSH-004 Scenario 04: partner missing or not determined in the order (Troubleshooting, 1 h)\n- TSH-005 Scenario 05: material not defined for sales organization or plant (Troubleshooting, 1 h)\n- PROJECT-001 SD master data project (Project, 6 h)\n- ASM-005 Phase 05 assessment: master data (Assessment, 2 h)\n\n## Phase 06 - Sales Documents\n\n### MOD-09 Sales Document Types, Structure and Flow\n\nTopics: Inquiry; Quotation; Sales order; Contracts; Scheduling agreements; Returns; Credit memo request; Debit memo request; Free-of-charge delivery; Cash sales; Rush orders; Header; Item; Schedule line; Document flow; Status management\n\n- THY-010 Sales document types and what each is for (Theory, 2 h)\n- THY-011 Header, item and schedule line (Theory, 3 h)\n- LAB-010 Create Inquiry (Lab, 2 h)\n- LAB-011 Create Quotation (Lab, 2 h)\n- LAB-012 Create Sales Order (Lab, 3 h)\n- PROC-001 Document flow and status management (Sales Process, 2 h)\n\n### MOD-10 Contracts and Scheduling Agreements\n\nTopics: Quantity contracts; Value contracts; Scheduling agreements; Contract release orders; Validity; Target values; Target quantities\n\n- THY-012 Outline agreements (Theory, 2 h)\n- PROC-002 Quantity contract and release orders (Sales Process, 3 h)\n- PROC-003 Value contract and scheduling agreement (Sales Process, 3 h)\n- ASM-006 Phase 06 assessment: sales documents (Assessment, 2 h)\n\n## Phase 07 - Sales Order Processing\n\n### MOD-11 Sales Order Configuration\n\nTopics: Sales document type; Number ranges; Item categories; Schedule line categories; Copy control; Partner determination; Pricing; Availability check; Delivery relevance; Billing relevance; Incompletion\n\n- CFG-005 Sales document type controls (Configuration, 4 h)\n- CFG-006 Incompletion procedures (Configuration, 2 h)\n\n### MOD-12 Item Categories and Schedule Line Categories\n\nTopics: Item category determination; Item category controls; Billing relevance; Delivery relevance; Pricing; Schedule line; Availability; Text; Incompletion; Schedule line determination; Transfer of requirements; Movement type\n\n- THY-013 Item category: controls and determination (Theory, 3 h)\n- LAB-013 Configure Item Category (Lab, 4 h)\n- THY-014 Schedule line category: controls and determination (Theory, 2 h)\n- LAB-014 Configure Schedule Line (Lab, 3 h)\n- TSH-006 Scenario 06: item category error, no item category available (Troubleshooting, 1 h)\n- TSH-007 Scenario 07: schedule line error, no schedule line or not delivery relevant (Troubleshooting, 1 h)\n\n### MOD-13 Copy Control\n\nTopics: Inquiry to quotation; Quotation to order; Order to delivery; Delivery to billing; Order to billing; Header copying; Item copying; Data transfer; Pricing transfer; Requirements; Routines concepts\n\n- THY-015 Copy control: what it governs (Theory, 3 h)\n- CFG-007 Copy control between sales documents (Configuration, 3 h)\n- CFG-008 Copy control order to delivery and delivery or order to billing (Configuration, 4 h)\n- TSH-008 Scenario 08: copy control error, reference not possible between document types (Troubleshooting, 1 h)\n- TSH-009 Scenario 09: prices change unexpectedly in the invoice (Troubleshooting, 1 h)\n\n### MOD-14 Text, Material Determination and Listing/Exclusion\n\nTopics: Header texts; Item texts; Customer texts; Material texts; Text determination; Copying text; Material substitution; Product selection; Customer-specific material; Reason for substitution; Customer/material listing; Exclusion; Condition technique\n\n- THY-016 Text determination (Theory, 2 h)\n- CFG-009 Configure text determination (Configuration, 3 h)\n- CFG-010 Material determination (Configuration, 3 h)\n- CFG-011 Listing and exclusion (Configuration, 3 h)\n- TSH-010 Scenario 10: sales order cannot be created for a customer and material (Troubleshooting, 1 h)\n- ASM-007 Phase 07 assessment: sales order configuration (Assessment, 3 h)\n\n## Phase 08 - Pricing\n\n### MOD-15 Pricing: the Condition Technique\n\nTopics: Condition technique; Condition tables; Access sequences; Condition types; Pricing procedures; Condition records; Pricing determination; Manual conditions; Discounts; Surcharges; Freight; Taxes; Rebates/settlement concepts\n\n- THY-017 Pricing as a business concept (Theory, 2 h)\n- THY-018 The condition technique (Theory, 4 h)\n- THY-019 Pricing procedure columns (Theory, 4 h)\n- CFG-012 Pricing procedure determination (Configuration, 2 h)\n- LAB-015 Configure Pricing (Lab, 6 h)\n- LAB-017 Material Pricing (Lab, 3 h)\n- LAB-016 Customer Pricing (Lab, 3 h)\n- PRICE-001 Manual conditions, header conditions and limits (Pricing, 3 h)\n- PRICE-002 Freight and surcharges (Pricing, 2 h)\n- THY-020 Rebates in ECC and settlement management concepts in S/4HANA (Theory, 2 h)\n- TSH-011 Scenario 11: pricing not determined, mandatory condition missing (Troubleshooting, 1 h)\n- TSH-012 Scenario 12: wrong pricing, an unexpected record is found (Troubleshooting, 1 h)\n- TSH-013 Scenario 13: pricing procedure not determined (Troubleshooting, 1 h)\n- ASM-008 Phase 08 assessment: pricing (Assessment, 3 h)\n\n## Phase 09 - Availability & ATP\n\n### MOD-16 Availability Check\n\nTopics: ATP; Availability check; Checking group; Checking rule; Scope of check; Confirmations; Requirements; Backorder concepts\n\n- THY-021 Available-to-promise and transfer of requirements (Theory, 3 h)\n- CFG-013 Configure the availability check (Configuration, 3 h)\n- LAB-018 Availability Check (Lab, 4 h)\n- PROC-004 Backorders and rescheduling (Sales Process, 2 h)\n- TSH-014 Scenario 14: ATP issue, order not confirmed although stock exists (Troubleshooting, 1 h)\n- TSH-015 Scenario 15: material unavailable, no schedule line date (Troubleshooting, 1 h)\n- ASM-009 Phase 09 assessment: availability (Assessment, 2 h)\n\n## Phase 10 - Shipping\n\n### MOD-17 Shipping and Route Determination\n\nTopics: Shipping point; Shipping conditions; Loading group; Route; Transportation; Delivery scheduling; Transportation group; Departure zone; Destination zone; Transit time; Loading time; Transportation scheduling\n\n- THY-022 Shipping point determination (Theory, 2 h)\n- CFG-014 Shipping point determination (Configuration, 2 h)\n- THY-023 Route determination (Theory, 2 h)\n- CFG-015 Route determination (Configuration, 4 h)\n- THY-024 Delivery and transportation scheduling (Theory, 3 h)\n- CFG-016 Delivery scheduling settings (Configuration, 2 h)\n- TSH-016 Scenario 16: shipping point missing in the order item (Troubleshooting, 1 h)\n- TSH-017 Scenario 17: route not determined (Troubleshooting, 1 h)\n- ASM-010 Phase 10 assessment: shipping (Assessment, 2 h)\n\n## Phase 11 - Delivery\n\n### MOD-18 Outbound Delivery\n\nTopics: Outbound delivery; Delivery creation; Delivery types; Item categories; Picking; Packing; Batch; Serial number concepts; Post Goods Issue\n\n- THY-025 The outbound delivery document (Theory, 2 h)\n- CFG-017 Delivery types and delivery item categories (Configuration, 3 h)\n- LAB-019 Create Delivery (Lab, 3 h)\n- SHIP-001 Delivery monitor and delivery changes (Shipping, 2 h)\n\n### MOD-19 Batch Determination and Serial Numbers\n\nTopics: Batch management; Batch search; Batch characteristics; Search strategy; Condition technique; Batch determination during sales/delivery; Serial number concepts\n\n- THY-026 Batch management and batch determination (Theory, 2 h)\n- CFG-018 Batch search strategy for deliveries (Configuration, 4 h)\n- THY-027 Serial number profiles (Theory, 1 h)\n- TSH-018 Scenario 18: delivery cannot be created (Troubleshooting, 1 h)\n- TSH-019 Scenario 19: delivery created for less than the order quantity (Troubleshooting, 1 h)\n- ASM-011 Phase 11 assessment: delivery (Assessment, 2 h)\n\n## Phase 12 - Picking & Packing\n\n### MOD-20 Picking\n\nTopics: Picking process; Picking relevance; Picking locations; Warehouse integration concepts; Manual picking; Automated picking concepts\n\n- THY-028 Picking and warehouse integration concepts (Theory, 2 h)\n- CFG-019 Picking location determination (Configuration, 2 h)\n- LAB-020 Picking (Lab, 2 h)\n\n### MOD-21 Packing\n\nTopics: Packaging; Handling units; Packing materials; Packing instructions; Delivery packing\n\n- THY-029 Packing and handling units (Theory, 2 h)\n- CFG-020 Packaging material types and allowed packaging (Configuration, 2 h)\n- LAB-021 Packing (Lab, 2 h)\n- TSH-020 Scenario 20: picking issue, storage location missing or picking incomplete (Troubleshooting, 1 h)\n- TSH-021 Scenario 21: packing not allowed for the packaging material (Troubleshooting, 1 h)\n- ASM-012 Phase 12 assessment: picking and packing (Assessment, 1 h)\n\n## Phase 13 - PGI\n\n### MOD-22 Post Goods Issue\n\nTopics: Stock reduction; Material document; Accounting document; COGS; Inventory valuation; Delivery status\n\n- THY-030 What goods issue does (Theory, 3 h)\n- LAB-022 Post Goods Issue (Lab, 3 h)\n- SHIP-002 Reverse goods issue (Shipping, 2 h)\n- TSH-022 Scenario 22: PGI failure, deficit of stock (Troubleshooting, 1 h)\n- TSH-023 Scenario 23: PGI failure, posting period or account determination (Troubleshooting, 2 h)\n- TSH-024 Scenario 24: goods issue posted but no accounting document (Troubleshooting, 1 h)\n- ASM-013 Phase 13 assessment: goods issue (Assessment, 1 h)\n\n## Phase 14 - Billing\n\n### MOD-23 Billing Process\n\nTopics: Invoice; Credit memo; Debit memo; Cancellation; Pro forma invoice; Billing types; Billing due list; Billing split; Billing block\n\n- THY-031 Billing documents and their types (Theory, 2 h)\n- LAB-023 Create Billing (Lab, 3 h)\n- BILL-001 Billing split, combination and billing blocks (Billing, 3 h)\n- BILL-002 Cancellation and pro forma invoice (Billing, 2 h)\n- LAB-024 Credit Memo (Lab, 3 h)\n\n### MOD-24 Billing Configuration\n\nTopics: Billing types; Number ranges; Copy control; Account determination; Pricing; Tax; Output; Cancellation\n\n- CFG-021 Billing types and number ranges (Configuration, 3 h)\n- CFG-022 Revenue account determination (Configuration, 4 h)\n- TSH-025 Scenario 25: billing block on the order or delivery (Troubleshooting, 1 h)\n- TSH-026 Scenario 26: billing split not wanted (Troubleshooting, 1 h)\n- TSH-027 Scenario 27: account determination error, invoice not released to accounting (Troubleshooting, 2 h)\n- TSH-028 Scenario 28: invoice cannot be created, delivery not yet relevant (Troubleshooting, 1 h)\n- ASM-014 Phase 14 assessment: billing (Assessment, 2 h)\n\n## Phase 15 - Credit Management\n\n### MOD-25 Credit Management\n\nTopics: Credit exposure; Credit limit; Credit check; Risk categories; Credit groups; Credit blocks; Release process; S/4HANA Credit Management\n\n- THY-032 Credit management concepts (Theory, 3 h)\n- CFG-023 Configure the credit check (Configuration, 4 h)\n- LAB-026 Credit Management (Lab, 4 h)\n- TSH-029 Scenario 29: credit block, order blocked although limit seems sufficient (Troubleshooting, 1 h)\n- TSH-030 Scenario 30: order not blocked although the limit is exceeded (Troubleshooting, 1 h)\n- ASM-015 Phase 15 assessment: credit management (Assessment, 2 h)\n\n## Phase 16 - Output Management\n\n### MOD-26 Output Management\n\nTopics: Output determination; Output types; Condition technique; Print; Email; PDF; EDI concepts; Forms; BRFplus concepts; S/4HANA output management\n\n- THY-033 Output determination with the condition technique (Theory, 3 h)\n- CFG-024 Classic output determination for order, delivery and billing (Configuration, 4 h)\n- THY-034 S/4HANA output management with BRFplus (Theory, 3 h)\n- CFG-025 Configure S/4HANA output parameter determination (Configuration, 3 h)\n- LAB-027 Output Management (Lab, 3 h)\n- TSH-031 Scenario 31: output failure, no output proposed (Troubleshooting, 1 h)\n- TSH-032 Scenario 32: output processed with error or wrong form (Troubleshooting, 1 h)\n- ASM-016 Phase 16 assessment: output management (Assessment, 2 h)\n\n## Phase 17 - Special Sales Processes\n\n### MOD-27 Cash Sales, Rush Orders and Free-of-Charge\n\nTopics: Cash sales; Rush orders; Free-of-charge delivery\n\n- PROC-005 Cash sale (Sales Process, 2 h)\n- PROC-006 Rush order (Sales Process, 2 h)\n- PROC-007 Free-of-charge delivery and subsequent delivery (Sales Process, 2 h)\n\n### MOD-28 Returns, Complaints, Credit and Debit Memo Processes\n\nTopics: Customer return; Return delivery; Goods receipt; Inspection; Credit memo; Customer complaint; Debit memo; Quality integration concepts\n\n- THY-035 Returns and complaint processing (Theory, 2 h)\n- LAB-025 Returns (Lab, 4 h)\n- PROC-008 Complaint with credit memo request and debit memo request (Sales Process, 2 h)\n\n### MOD-29 Third-Party Sales and Individual Purchase Orders\n\nTopics: Customer order; Purchase requisition; Purchase order; Vendor; Vendor delivery; Customer billing; Third-party sales; Individual purchase orders; SD-MM integration\n\n- THY-036 Third-party and individual purchase order processing (Theory, 3 h)\n- PROC-009 Third-party order end to end (Sales Process, 4 h)\n- PROC-010 Individual purchase order end to end (Sales Process, 3 h)\n\n### MOD-30 Make-to-Order and Consignment\n\nTopics: Make-to-order: sales order, requirement, procurement or production, stock, delivery, billing; Consignment fill-up; Consignment issue; Consignment pickup; Consignment return\n\n- THY-037 Make-to-order (Theory, 2 h)\n- PROC-011 Make-to-order end to end (Sales Process, 3 h)\n- THY-038 Consignment (Theory, 2 h)\n- PROC-012 Consignment end to end (Sales Process, 4 h)\n- TSH-033 Scenario 33: third-party order creates no purchase requisition (Troubleshooting, 1 h)\n- TSH-034 Scenario 34: third-party order cannot be billed (Troubleshooting, 1 h)\n- TSH-035 Scenario 35: returns credit memo blocked or wrong value (Troubleshooting, 1 h)\n- TSH-036 Scenario 36: consignment issue fails for lack of stock (Troubleshooting, 1 h)\n- ASM-017 Phase 17 assessment: special processes (Assessment, 3 h)\n\n## Phase 18 - FI Integration\n\n### MOD-31 SD-FI Integration\n\nTopics: Sales order; Delivery; PGI; Billing; FI accounting document; Customer receivable; Revenue; Tax; Customer account; Revenue account; Tax account; COGS; Inventory; Profit center\n\n- THY-039 Accounting documents created by sales (Theory, 3 h)\n- LAB-028 FI Integration (Lab, 4 h)\n- INT-001 Trace every amount from pricing to the ledger (Integration, 3 h)\n\n### MOD-32 Taxation in Sales\n\nTopics: Tax determination; Customer tax classification; Material tax classification; Country; Region; Tax codes; Pricing conditions; FI tax integration; GST and VAT concepts\n\n- THY-040 Tax determination in sales (Theory, 3 h)\n- CFG-026 Configure tax determination (Configuration, 4 h)\n- TSH-037 Scenario 37: tax not determined in the order (Troubleshooting, 1 h)\n- TSH-038 Scenario 38: invoice posts to the wrong revenue account (Troubleshooting, 1 h)\n- TSH-039 Scenario 39: profit centre missing on the sales document (Troubleshooting, 1 h)\n- ASM-018 Phase 18 assessment: FI integration (Assessment, 2 h)\n\n## Phase 19 - MM Integration\n\n### MOD-33 SD-MM Integration\n\nTopics: Material; Stock; Plant; Availability; Delivery; Goods issue; Inventory; Procurement interaction; How SD interacts with MM during order fulfillment\n\n- THY-041 Where sales touches materials management (Theory, 3 h)\n- LAB-029 MM Integration (Lab, 4 h)\n- INT-002 Movement types and account determination for sales (Integration, 3 h)\n- TSH-040 Scenario 40: stock exists but in the wrong storage location or stock type (Troubleshooting, 1 h)\n- ASM-019 Phase 19 assessment: MM integration (Assessment, 2 h)\n\n## Phase 20 - CO Integration\n\n### MOD-34 SD-CO Integration\n\nTopics: Profit center; Cost; Revenue; Margin; Profitability; CO-PA; Internal reporting\n\n- THY-042 Profitability and profit centres from sales (Theory, 3 h)\n- LAB-035 Margin from order to report (Lab, 3 h)\n- ASM-020 Phase 20 assessment: CO integration (Assessment, 1 h)\n\n## Phase 21 - S/4HANA Sales\n\n### MOD-35 SAP S/4HANA Sales\n\nTopics: S/4HANA architecture; Business Partner; Fiori; Simplification; Advanced ATP; Credit Management; Output Management; Embedded analytics; APIs; Extensibility concepts\n\n- THY-043 S/4HANA architecture and the sales simplifications (Theory, 4 h)\n- THY-044 Data model changes in sales (Theory, 2 h)\n- LAB-030 S/4HANA Sales (Lab, 4 h)\n- THY-045 APIs and extensibility concepts (Theory, 2 h)\n- THY-046 Settlement management concepts (Theory, 2 h)\n- ASM-021 Phase 21 assessment: S/4HANA sales (Assessment, 2 h)\n\n## Phase 22 - Fiori\n\n### MOD-36 SAP Fiori for Sales\n\nTopics: Fiori Launchpad; Sales order apps; Customer apps; Delivery apps; Billing apps; Analytics; KPI tiles; Fact sheets\n\n- THY-047 Fiori app types, roles and the apps reference library (Theory, 2 h)\n- LAB-036 Fiori scenario: internal sales representative (Lab, 3 h)\n- LAB-037 Fiori scenario: shipping specialist and billing clerk (Lab, 3 h)\n\n### MOD-37 Sales Reporting and Analytics\n\nTopics: Sales volume; Revenue; Customer performance; Material performance; Order status; Delivery status; Billing status; Margin; Backorders; Credit exposure; Sales, customer, material, order, delivery and billing reports; Open orders; Revenue reports; S/4HANA analytical concepts\n\n- LAB-038 List reports for orders, deliveries and billing (Lab, 3 h)\n- LAB-039 Analytics: sales volume, incoming orders and margin (Lab, 3 h)\n- ASM-022 Phase 22 assessment: Fiori and reporting (Assessment, 2 h)\n\n## Phase 23 - Advanced ATP\n\n### MOD-38 Advanced Available-to-Promise\n\nTopics: Product availability check; Backorder processing; Product allocation; Alternative-based confirmation; Supply protection; Advanced ATP architecture; Classic ATP versus advanced ATP\n\n- THY-048 Advanced ATP architecture and how it differs from classic ATP (Theory, 3 h)\n- LAB-040 Product availability check in advanced ATP (Lab, 3 h)\n- THY-049 Backorder processing: segments, variants and confirmation strategies (Theory, 3 h)\n- LAB-041 Backorder processing run (Lab, 4 h)\n- THY-050 Product allocation concepts (Theory, 2 h)\n- LAB-042 Product allocation (Lab, 4 h)\n- THY-051 Alternative-based confirmation and supply protection concepts (Theory, 2 h)\n- LAB-043 Alternative-based confirmation walkthrough (Lab, 2 h)\n- TSH-041 Scenario 41: order unconfirmed after a backorder run (Troubleshooting, 1 h)\n- TSH-042 Scenario 42: order not confirmed although stock exists, product allocation exhausted (Troubleshooting, 1 h)\n- ASM-023 Phase 23 assessment: advanced ATP (Assessment, 2 h)\n\n## Phase 24 - Advanced Pricing\n\n### MOD-39 Advanced Pricing\n\nTopics: Customer discounts; Material discounts; Customer/material pricing; Quantity discounts and scales; Promotional pricing; Freight; Taxes; Manual pricing; Statistical conditions; Accrual conditions; Condition exclusion; Condition supplements; Group conditions; Free goods; Pricing dates and validity\n\n- THY-052 How consultants design pricing: from price list to pricing procedure (Theory, 3 h)\n- PRICE-003 Customer discounts, material discounts and customer/material prices (Pricing, 3 h)\n- PRICE-004 Quantity discounts, scales and group conditions (Pricing, 3 h)\n- PRICE-005 Promotional pricing, sales deals and free goods (Pricing, 3 h)\n- CFG-027 Freight, surcharges and manual conditions with limits (Configuration, 3 h)\n- CFG-028 Statistical and accrual conditions (Configuration, 3 h)\n- CFG-029 Condition exclusion and condition supplements (Configuration, 3 h)\n- CFG-030 Requirements, formulas and pricing type in copy control (Configuration, 2 h)\n- TSH-043 Scenario 43: discount not applied although a record exists (Troubleshooting, 1 h)\n- TSH-044 Scenario 44: condition is found twice or the net value is wrong (Troubleshooting, 1 h)\n- TSH-045 Scenario 45: manual price change is refused or lost on billing (Troubleshooting, 1 h)\n\n### MOD-40 Advanced Pricing Project\n\nTopics: Base price; Customer discount; Material discount; Quantity discount; Freight; Tax; Promotional discount; Manual discount; Exclusion; Complete pricing procedure; Explanation of every condition\n\n- PROJECT-002 Advanced pricing project part 1: design and configuration (Project, 8 h)\n- PROJECT-003 Advanced pricing project part 2: records, test and explanation (Project, 6 h)\n- ASM-024 Phase 24 assessment: advanced pricing (Assessment, 3 h)\n\n## Phase 25 - Testing\n\n### MOD-41 Testing SAP SD\n\nTopics: Unit testing; Integration testing; User acceptance testing; Regression testing; Negative testing; End-to-end testing; Test scripts; Test evidence; Defect management\n\n- THY-053 Test levels and what each one proves (Theory, 2 h)\n- TEST-001 Test script and evidence standards (Testing, 2 h)\n- TEST-002 Test scenarios 1-10: master data and sales documents (Testing, 5 h)\n- TEST-003 Test scenarios 11-20: pricing, availability, shipping and delivery (Testing, 5 h)\n- TEST-004 Test scenarios 21-30: billing, credit, output and special processes (Testing, 5 h)\n- TEST-005 Negative tests (Testing, 3 h)\n- TEST-006 Integration and end-to-end test: order to cash with finance and materials (Testing, 4 h)\n- TEST-007 Regression pack, user acceptance test and defect management (Testing, 3 h)\n- ASM-025 Phase 25 assessment: testing (Assessment, 2 h)\n\n## Phase 26 - Migration\n\n### MOD-42 SD Data Migration\n\nTopics: Customer; Business Partner; Material; Pricing; Open sales orders; Open deliveries; Other sales data such as customer-material info records, contracts and credit data; Migration Cockpit; Templates; APIs; BAPI concepts; Data validation; Reconciliation\n\n- THY-054 Migration objects, sequence and reconciliation for sales (Theory, 3 h)\n- THY-055 Migration tools: Migration Cockpit, templates, APIs, BAPI and legacy tools (Theory, 2 h)\n- LAB-044 Migrate business partners and customers (Lab, 4 h)\n- LAB-045 Migrate materials and customer-material information (Lab, 3 h)\n- LAB-046 Migrate pricing conditions (Lab, 3 h)\n- LAB-047 Migrate open sales orders and handle open deliveries (Lab, 4 h)\n- DOC-001 Data migration plan for sales (Documentation, 3 h)\n- TSH-046 Scenario 46: migration load fails validation (Troubleshooting, 1 h)\n- TSH-047 Scenario 47: migrated customers cannot be used in orders (Troubleshooting, 1 h)\n- ASM-026 Phase 26 assessment: migration (Assessment, 2 h)\n\n## Phase 27 - Implementation\n\n### MOD-43 Implementation Methodology\n\nTopics: SAP Activate; Discover; Prepare; Explore; Realize; Deploy; Run; Fit-to-standard; Fit-gap; Requirement to production: requirement, business process, fit-gap, configuration, unit test, integration test, UAT, transport, production\n\n- THY-056 SAP Activate and its phases (Theory, 3 h)\n- THY-057 How consultants configure: requirement to production (Theory, 3 h)\n- IMPL-001 Fit-to-standard workshop and fit-gap document for sales (Implementation, 4 h)\n- IMPL-002 IMG navigation for SD and transport requests (Implementation, 4 h)\n\n### MOD-44 Implementation Documentation\n\nTopics: Business Requirement Document; Fit-Gap Analysis; Business Process Document; Configuration Document; Functional Specification; Test Script; Test Evidence; Data Migration Plan; Cutover Plan; Go-Live Checklist; Support Runbook; RCA; User Training Material\n\n- DOC-002 Business requirement document and business process document (Documentation, 4 h)\n- DOC-003 Configuration document (Documentation, 3 h)\n- DOC-004 Functional specification for an enhancement (Documentation, 3 h)\n- DOC-005 User training material (Documentation, 3 h)\n\n### MOD-45 Cutover and Go-Live\n\nTopics: Cutover plan; Open document strategy; Number ranges; Transports; Go-live checklist; Hypercare\n\n- THY-058 Cutover and go-live for sales (Theory, 2 h)\n- DOC-006 Cutover plan and go-live checklist (Documentation, 4 h)\n\n### MOD-46 SAP SD Security Concepts\n\nTopics: Roles; Authorization objects for sales documents, deliveries and billing; Organizational levels; Segregation of duties\n\n- THY-059 Functional security for sales: roles, organizational levels and segregation of duties (Theory, 2 h)\n- IMPL-003 Authorization failure analysis and role requirement (Implementation, 2 h)\n\n### MOD-47 Month-End Sales Closing\n\nTopics: Open deliveries; Billing completion; Billing blocks; Credit blocks; Returns; Billing reconciliation; Revenue reporting; FI reconciliation\n\n- THY-060 Why sales closes the month and what finance needs (Theory, 2 h)\n- PROC-013 Month-end sales closing run (Sales Process, 6 h)\n- DOC-007 Month-end sales closing checklist for the course company (Documentation, 2 h)\n\n### MOD-48 SD Implementation Project: Global Manufacturing Corporation\n\nTopics: Company; Company Code; Sales Organization; Distribution Channel; Division; Sales Area; Plant; Shipping Point; Customers; Materials; Pricing; Sales; Delivery; Billing; Output\n\n- PROJECT-004 SD implementation project part 1: enterprise structure and master data (Project, 10 h)\n- PROJECT-005 SD implementation project part 2: sales and pricing (Project, 10 h)\n- PROJECT-006 SD implementation project part 3: delivery, billing and output (Project, 10 h)\n- ASM-027 Phase 27 assessment: implementation (Assessment, 3 h)\n\n## Phase 28 - Production Support\n\n### MOD-49 Production Support\n\nTopics: Incident management; Problem management; Change management; SLA; Severity; Priority; RCA; Functional troubleshooting; Configuration troubleshooting\n\n- THY-061 Support processes: incident, problem, change, severity, priority and SLA (Theory, 3 h)\n- LAB-048 Support tools: jobs, logs, dumps, authorization and document analysis (Lab, 4 h)\n- SUP-001 Support ticket exercises: ten tickets (Support, 6 h)\n- DOC-008 Root cause analysis report and support runbook (Documentation, 4 h)\n\n### MOD-50 Troubleshooting SAP SD\n\nTopics: Functional troubleshooting; Configuration troubleshooting; The eight-section report: problem, business impact, evidence, root cause, configuration, fix, validation, prevention\n\n- THY-062 Troubleshooting method and the eight-section report (Theory, 2 h)\n- TSH-048 Scenario 48: configuration works in development but not in quality, transport missing (Troubleshooting, 2 h)\n- TSH-049 Scenario 49: order type not allowed in the sales area (Troubleshooting, 1 h)\n- TSH-050 Scenario 50: incompletion log blocks delivery or billing unexpectedly (Troubleshooting, 1 h)\n- TSH-051 Scenario 51: delivery is created but the wrong plant or shipping point is proposed (Troubleshooting, 1 h)\n- TSH-052 Scenario 52: billing due list does not show a delivered order (Troubleshooting, 1 h)\n- TSH-053 Scenario 53: invoice value differs from the order value (Troubleshooting, 2 h)\n- TSH-054 Scenario 54: text or partner is not copied to the delivery or invoice (Troubleshooting, 1 h)\n- TSH-055 Scenario 55: returns stock is posted to unrestricted stock by mistake (Troubleshooting, 1 h)\n- TSH-056 Scenario 56: background billing job ends with errors (Troubleshooting, 2 h)\n- TSH-057 Scenario 57: customer receives no invoice by e-mail (Troubleshooting, 1 h)\n- TSH-058 Scenario 58: month-end multi-fault case in order to cash (Troubleshooting, 4 h)\n- ASM-028 Troubleshooting assessment (Assessment, 3 h)\n\n## Phase 29 - Advanced Consulting\n\n### MOD-51 Real-World Business Scenarios\n\nTopics: Scenario method: understand requirement, identify SAP process, identify configuration, execute transaction or Fiori app, validate document flow, validate accounting and logistics impact, document solution\n\n- SCN-001 Scenario 1: Standard Order-to-Cash (Scenario, 4 h)\n- SCN-002 Scenario 2: Cash Sales (Scenario, 3 h)\n- SCN-003 Scenario 3: Rush Order (Scenario, 3 h)\n- SCN-004 Scenario 4: Returns (Scenario, 3 h)\n- SCN-005 Scenario 5: Third-Party Sales (Scenario, 4 h)\n- SCN-006 Scenario 6: Make-to-Order (Scenario, 4 h)\n- SCN-007 Scenario 7: Consignment (Scenario, 4 h)\n- SCN-008 Scenario 8: Contract Sales (Scenario, 3 h)\n- SCN-009 Scenario 9: Customer-Specific Pricing (Scenario, 3 h)\n- SCN-010 Scenario 10: Credit Management (Scenario, 3 h)\n\n### MOD-52 End-to-End Order-to-Cash Project\n\nTopics: Customer; Inquiry; Quotation; Sales Order; ATP; Delivery; Picking; Packing; PGI; Billing; FI Posting; Incoming Payment; Validation of every document and its accounting and logistics impact\n\n- PROJECT-007 End-to-end O2C project (Project, 8 h)\n\n### MOD-53 Enterprise SD Project: Multi-Country Sales\n\nTopics: Multiple sales organizations; Multiple distribution channels; Multiple divisions; Multiple plants; Multiple shipping points; Multiple currencies; Multiple tax scenarios; Multiple customer groups; Multiple pricing strategies; Intercompany sales concepts\n\n- PROJECT-008 Enterprise SD project part 1: design (Project, 8 h)\n- PROJECT-009 Enterprise SD project part 2: build and prove (Project, 10 h)\n\n### MOD-54 Transaction Code and Fiori App Curriculum\n\nTopics: For every important code: purpose, business scenario, input, output, related configuration, common errors, corresponding Fiori app; General codes; SD codes for master data, sales, delivery, billing, pricing, shipping, credit and output\n\n- DOC-009 Transaction reference: general, master data and sales (Documentation, 4 h)\n- DOC-010 Transaction reference: pricing, shipping, delivery, billing, credit and output (Documentation, 4 h)\n\n### MOD-55 Solution Design and Advanced Topics\n\nTopics: Solution architecture; Intercompany sales; Settlement management; Advanced returns management; Variant configuration; Transportation and warehouse integration concepts; Interfaces and EDI\n\n- THY-063 Advanced sales topics at concept level (Theory, 4 h)\n- IMPL-004 Solution design for a client requirement (Implementation, 5 h)\n\n### MOD-56 Career Preparation\n\nTopics: Roles: SAP SD Consultant, S/4HANA Sales Consultant, SD Functional Consultant, O2C Consultant, SD Support Consultant, SD Implementation Consultant; Interview questions; Client interview simulations; Project explanation practice\n\n- DOC-011 Interview bank: SD basics, O2C scenarios and pricing (Documentation, 4 h)\n- DOC-012 Interview bank: configuration, integration and S/4HANA (Documentation, 4 h)\n- DOC-013 Interview bank: troubleshooting scenarios (Documentation, 3 h)\n- DOC-014 Resume and project explanation (Documentation, 3 h)\n- ASM-029 Mock interviews: functional, configuration and client simulation (Assessment, 3 h)\n\n## Phase 30 - Enterprise Capstone\n\n### MOD-57 Capstone: Enterprise SAP S/4HANA Sales Implementation for Global Manufacturing Corporation\n\nTopics: Organizational structure: company, company code, sales organization, distribution channel, division, sales area, plant, shipping point; Master data: business partner, customer, material, pricing, partner determination; Processes: inquiry, quotation, sales order, ATP, delivery, picking, packing, PGI, billing, returns, credit memo; Advanced: pricing, credit management, output, route, tax, FI, MM and CO integration; Nineteen deliverables\n\n- CAP-001 Business requirements and organizational structure (Capstone, 6 h)\n- CAP-002 Sales process design and master-data design (Capstone, 6 h)\n- CAP-003 Pricing design and configuration (Capstone, 8 h)\n- CAP-004 Sales, shipping and billing design and configuration (Capstone, 12 h)\n- CAP-005 Credit-management, output and integration design and configuration (Capstone, 8 h)\n- CAP-006 Configuration document (Capstone, 5 h)\n- CAP-007 Test scripts and test evidence (Capstone, 8 h)\n- CAP-008 Execute the capstone business processes (Capstone, 12 h)\n- CAP-009 Migration plan, cutover plan and go-live checklist (Capstone, 6 h)\n- CAP-010 Production-support runbook and troubleshooting guide (Capstone, 4 h)\n- CAP-011 Final technical documentation and executive presentation (Capstone, 5 h)\n- ASM-030 Final assessment (Assessment, 3 h)\n",
   "parent": "Wiki"
  }
 ]
}
