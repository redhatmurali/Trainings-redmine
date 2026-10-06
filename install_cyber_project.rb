# Cybersecurity & Security Operations Engineering - one-shot Redmine installer
#
# Put this file and cyber_issues.csv in the same folder. Run on the Redmine server,
# from the Redmine root directory, as the Redmine OS user:
#
#   STUDENTS=alice,bob INSTRUCTORS=admin \
#     bundle exec rails runner -e production /path/to/install_cyber_project.rb
#
# Environment variables (all optional):
#   CSV            path to cyber_issues.csv (default: same folder as this script)
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
csv_path   = File.join(course_dir, 'cyber_issues.csv') if csv_path.empty?
halt("not found: #{csv_path} (set CSV=/path/to/cyber_issues.csv)") unless File.file?(csv_path)

# The project definition (fields, queries, wiki pages) is embedded at the end of this file.
embedded = File.read(File.expand_path(__FILE__), :encoding => 'utf-8').split("\n__END__\n", 2)[1]
halt('embedded project definition missing from this script') if embedded.to_s.strip.empty?
course = JSON.parse(embedded)
$tag   = course['tag'].to_s.empty? ? 'course' : course['tag']
rows   = CSV.read(csv_path, :headers => true, :encoding => 'bom|utf-8').map(&:to_h)
halt('cyber_issues.csv is empty') if rows.empty?
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
 "tag": "cyber",
 "project": {
  "name": "Cybersecurity & Security Operations Engineering",
  "identifier": "cybersecurity-security-operations-engineering",
  "description": "Professional, job-oriented Cybersecurity & Security Operations Engineering programme. Concept -> Tool -> Lab -> Investigation -> Automation -> Real-world scenario, across 15 phases, ending in an Enterprise SOC capstone. One shared project; every student has a personal copy of each issue. Step-by-step lab guides live in the wiki, one page per module."
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
   "name": "Lab",
   "kind": "work"
  },
  {
   "name": "Assignment",
   "kind": "work"
  },
  {
   "name": "Investigation",
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
   "name": "Troubleshooting",
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
  "Investigation"
 ],
 "versions": [
  "V01.0 Cybersecurity Foundations",
  "V02.0 Networking & Network Security",
  "V03.0 Linux Security",
  "V04.0 Windows & Active Directory Security",
  "V05.0 IAM & Cryptography",
  "V06.0 Vulnerability & Web Security",
  "V07.0 SOC & SIEM",
  "V08.0 Detection Engineering",
  "V09.0 Threat Intelligence",
  "V10.0 Incident Response & DFIR",
  "V11.0 Threat Hunting & Malware",
  "V12.0 Cloud & DevSecOps",
  "V13.0 Security Automation",
  "V14.0 Advanced Security Engineering",
  "V15.0 Enterprise SOC Capstone"
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
   "name": "MITRE Technique",
   "format": "string",
   "trackers": "work",
   "searchable": true,
   "csv": "MITRE Technique"
  },
  {
   "name": "Skill Level",
   "format": "list",
   "trackers": "all",
   "values": [
    "Foundation",
    "Core",
    "Advanced",
    "Enterprise"
   ],
   "csv": "Skill Level"
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
   "name": "Job Skill",
   "format": "list",
   "multiple": true,
   "trackers": "all",
   "csv": "Job Skill",
   "sort": true
  },
  {
   "name": "Output Type",
   "format": "list",
   "trackers": "work",
   "values": [
    "Detection rule",
    "Threat hunt",
    "Automation workflow",
    "Incident investigated",
    "Vulnerability remediated"
   ],
   "csv": "Output Type"
  },
  {
   "name": "Output Count",
   "format": "int",
   "trackers": "work",
   "csv": "Output Count"
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
      "tracker:Lab"
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
   "name": "Dashboard: incidents investigated",
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
     "cf:Output Type",
     "=",
     [
      "Incident investigated"
     ]
    ]
   ],
   "columns": [
    "cf:Curriculum ID",
    "subject",
    "cf:Output Count",
    "closed_on"
   ],
   "group_by": null,
   "totals": [
    "cf:Output Count"
   ],
   "sort": [
    [
     "id",
     "asc"
    ]
   ]
  },
  {
   "name": "Dashboard: detection rules created",
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
     "cf:Output Type",
     "=",
     [
      "Detection rule"
     ]
    ]
   ],
   "columns": [
    "cf:Curriculum ID",
    "subject",
    "cf:Output Count",
    "closed_on"
   ],
   "group_by": null,
   "totals": [
    "cf:Output Count"
   ],
   "sort": [
    [
     "id",
     "asc"
    ]
   ]
  },
  {
   "name": "Dashboard: threat hunts completed",
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
     "cf:Output Type",
     "=",
     [
      "Threat hunt"
     ]
    ]
   ],
   "columns": [
    "cf:Curriculum ID",
    "subject",
    "cf:Output Count",
    "closed_on"
   ],
   "group_by": null,
   "totals": [
    "cf:Output Count"
   ],
   "sort": [
    [
     "id",
     "asc"
    ]
   ]
  },
  {
   "name": "Dashboard: automation workflows created",
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
     "cf:Output Type",
     "=",
     [
      "Automation workflow"
     ]
    ]
   ],
   "columns": [
    "cf:Curriculum ID",
    "subject",
    "cf:Output Count",
    "closed_on"
   ],
   "group_by": null,
   "totals": [
    "cf:Output Count"
   ],
   "sort": [
    [
     "id",
     "asc"
    ]
   ]
  },
  {
   "name": "Dashboard: vulnerabilities remediated",
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
     "cf:Output Type",
     "=",
     [
      "Vulnerability remediated"
     ]
    ]
   ],
   "columns": [
    "cf:Curriculum ID",
    "subject",
    "cf:Output Count",
    "closed_on"
   ],
   "group_by": null,
   "totals": [
    "cf:Output Count"
   ],
   "sort": [
    [
     "id",
     "asc"
    ]
   ]
  },
  {
   "name": "Dashboard: MITRE techniques covered",
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
     "cf:MITRE Technique",
     "*",
     null
    ]
   ],
   "columns": [
    "cf:Curriculum ID",
    "subject",
    "cf:MITRE Technique"
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
      "tracker:Project+Capstone"
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
   "name": "Dashboard: skills by level",
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
   "group_by": "cf:Skill Level",
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
     "category_id",
     "=",
     [
      "category:Career"
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
   "name": "Instructor: outputs by student",
   "roles": "staff",
   "filters": [
    [
     "status_id",
     "=",
     [
      "status:Completed"
     ]
    ],
    [
     "cf:Output Type",
     "*",
     null
    ]
   ],
   "columns": [
    "cf:Curriculum ID",
    "subject",
    "cf:Output Type",
    "cf:Output Count"
   ],
   "group_by": "assigned_to",
   "totals": [
    "cf:Output Count"
   ],
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
   "text": "# Cybersecurity & Security Operations Engineering\n\nProfessional, job-oriented Cybersecurity & Security Operations Engineering programme. Concept -> Tool -> Lab -> Investigation -> Automation -> Real-world scenario, across 15 phases, ending in an Enterprise SOC capstone. One shared project; every student has a personal copy of each issue. Step-by-step lab guides live in the wiki, one page per module.\n\n## How to work an issue\n\n1. Open your next issue from the saved query *My next tasks*.\n2. Set the status to **In Progress** and open the module guide linked in the issue.\n3. Do the steps. Log time at the end of every session.\n4. Set **Testing**, verify the expected result, attach the evidence.\n5. Set **Review**. The instructor sets **Completed** or **Reopened**.\n\n## Pages\n\n- [[Lab_Infrastructure]]\n- [[Authorized_Use]]\n- [[Workflow_and_Statuses]]\n- [[Assessment_and_Grading]]\n- [[Evidence_Standards]]\n- [[Report_Templates]]\n- [[Dashboard_Guide]]\n- [[Skill_Matrix]]\n- [[Tool_Matrix]]\n- [[Module_Guides]]",
   "parent": null
  },
  {
   "title": "Lab_Infrastructure",
   "text": "# Lab infrastructure\n\n| System | Minimum size | Purpose |\n|---|---|---|\n| Firewall | 1 vCPU / 1 GB / 8 GB | Routing, NAT, zone rules, firewall logs |\n| Linux server (Debian family) | 2 vCPU / 4 GB / 40 GB | Services, auditd, hardening labs |\n| Linux server (RHEL family) | 2 vCPU / 4 GB / 40 GB | SELinux, OpenSCAP, second log source |\n| Windows Server (domain controller) | 2 vCPU / 4 GB / 60 GB | Active Directory, DNS, GPO, Sysmon |\n| Windows client | 2 vCPU / 4 GB / 60 GB | User workstation, Sysmon, Defender |\n| Network sensor | 2 vCPU / 4 GB / 60 GB | Zeek and Suricata on a mirrored interface |\n| SIEM server | 4 vCPU / 8 GB / 100 GB | Wazuh server, indexer and dashboard |\n| Security tools server | 4 vCPU / 12 GB / 100 GB | Grafana, Prometheus, Loki, TheHive, MISP, n8n |\n| Analysis workstation | 2 vCPU / 4 GB / 60 GB | Forensics and sample analysis, isolated |\n| Authorized test source | 2 vCPU / 4 GB / 40 GB | Source of instructor-approved simulations, own segment |\n\nRun the systems in groups if the host is small. Cloud alternative: run the SIEM server and the security tools server on cloud instances and keep endpoints local; AWS and Azure labs need trial or low-cost accounts with a budget alert.\n\n```\nFirewall -> IDS/IPS sensor -> Lab network -> Linux + Windows -> Sysmon / auditd -> Wazuh\n  -> Zeek + Suricata -> Log pipeline -> SIEM -> Grafana -> Detection engineering\n  -> Threat intelligence -> TheHive -> Velociraptor -> n8n automation -> Incident response\n```",
   "parent": "Wiki"
  },
  {
   "title": "Authorized_Use",
   "text": "# Authorized use\n\n- All testing and simulation is performed only inside the course lab and only against systems the instructor has approved.\n- Web and API security labs use authorized training applications only.\n- Analysis labs use instructor-provided training samples only.\n- Nothing from the lab is pointed at any external system.\n- Each student confirms these rules in a note on THY-001 before starting.",
   "parent": "Wiki"
  },
  {
   "title": "Workflow_and_Statuses",
   "text": "# Workflow and statuses\n\n| Status | Meaning |\n|---|---|\n| New | Template or unassigned |\n| Assigned | Belongs to a student, not started |\n| In Progress | Being worked on |\n| Blocked | Cannot continue; a note states the blocker |\n| Testing | Steps done; student verifies the result and collects evidence |\n| Review | Submitted to the instructor |\n| Completed | Approved by the instructor |\n| Reopened | Changes requested |\n| Rejected | Waived or not applicable (instructor only) |\n\nPrerequisites are *blocked by* relations: an issue cannot be closed while its blocker is open.",
   "parent": "Wiki"
  },
  {
   "title": "Assessment_and_Grading",
   "text": "# Assessment and grading\n\n| Element | Where | Scoring |\n|---|---|---|\n| Knowledge | Theory issues and MCQ + scenario assessments | Short answers, MCQ, scenario and architecture questions |\n| Practical | Lab and Investigation issues, practical exams | Evidence checked against the expected result; reports graded |\n| Projects | Project issues (small to advanced) | 0-100 on result, documentation and repository |\n| Capstone | CAP issues and the final assessment | 0-100 against the capstone rubric |\n\nPass mark 70. Programme grade: phase assessments 30 %, projects 30 %, capstone 40 %. The programme cannot be completed through theory alone: every phase gate requires its labs and investigations.",
   "parent": "Wiki"
  },
  {
   "title": "Evidence_Standards",
   "text": "# Evidence standards\n\n| Evidence | Minimum content |\n|---|---|\n| Notes | Own words, one page, diagrams where useful |\n| Screenshot + command output | Shows hostname, time and the result; text output pasted as text |\n| Investigation report | Summary, timeline, evidence, root cause, impact, containment, recommendations, ATT&CK mapping |\n| Repository link | Commit link with README, rule or code, and test evidence |\n| Repository link + documentation | Repository plus architecture, setup and operation notes |\n| Written deliverable | Document attached or linked, reviewed against the module concepts |\n| Root cause report | Symptom, cause, fix, prevention |\n| Scored result | Score and feedback recorded by the instructor |",
   "parent": "Wiki"
  },
  {
   "title": "Report_Templates",
   "text": "# Report templates\n\n## Investigation report\n\nSummary; Scope; Timeline; Evidence; Analysis; Root cause; Impact; Containment and recovery; Recommendations; ATT&CK mapping.\n\n## Detection rule record\n\nName; Goal; ATT&CK technique; Data source; Logic; Severity; False positives; Test evidence; Tuning notes.\n\n## Threat hunt record\n\nHypothesis; Data sources; Queries; Findings; Outcome; New detections.\n\n## Automation workflow record\n\nTrigger; Inputs; Steps; Approvals; Outputs; Failure handling.\n\n## Executive report\n\nWhat happened; Business impact; Current status; Decisions needed; Next steps.",
   "parent": "Wiki"
  },
  {
   "title": "Dashboard_Guide",
   "text": "# Dashboard guide\n\nThe dashboard is the set of saved queries in the issue list sidebar. Add them to *My page* as custom query blocks.\n\n| Area | Saved query | Reads |\n|---|---|---|\n| Course progress | Dashboard: overall completion | % done of the Epic issue |\n| Course progress | Dashboard: phase completion | % done per Phase issue |\n| Course progress | Dashboard: module completion | % done per Module issue |\n| Course progress | Dashboard: labs completed / assessments | Closed Lab and Assessment issues |\n| Security metrics | Dashboard: incidents investigated | Closed Investigation issues, total Output Count |\n| Security metrics | Dashboard: detection rules created | Closed issues with Output Type = Detection rule, total Output Count |\n| Security metrics | Dashboard: threat hunts / automation workflows / vulnerabilities remediated | Same, by Output Type |\n| Security metrics | Dashboard: MITRE techniques covered | Closed issues with a MITRE Technique value |\n| Security metrics | Dashboard: projects completed | Closed Project and Capstone issues |\n| Career readiness | Dashboard: skills by level | Open and closed work grouped by Skill Level |\n| Career readiness | My portfolio projects | Issues with Portfolio Project = yes |\n| Career readiness | Dashboard: interview readiness | Career category issues |\n\nFor % done to follow the status, set *Administration > Settings > Issue tracking > Calculate the issue done ratio* to *Use the issue status* (global setting).",
   "parent": "Wiki"
  },
  {
   "title": "Skill_Matrix",
   "text": "# Skill matrix\n\n| Security domain | Skill level | Modules | Tasks | Hours | Job roles |\n|---|---|---|---|---|---|\n| Foundations | Foundation | MOD-01, MOD-02, MOD-03, MOD-04 | 14 | 43 | Security Operations Engineer, Cybersecurity Engineer |\n| Network Security | Core | MOD-05, MOD-06, MOD-07, MOD-08, MOD-09, MOD-10, MOD-11 | 34 | 116 | SOC Engineer, Infrastructure Security Engineer |\n| Linux Security | Core | MOD-12, MOD-13, MOD-14, MOD-15 | 18 | 63 | Infrastructure Security Engineer, SOC Analyst |\n| Security Programming | Core | MOD-16, MOD-18, MOD-56 | 17 | 74 | Security Automation Engineer |\n| Windows Security | Core | MOD-17, MOD-19, MOD-20, MOD-22 | 17 | 68 | Infrastructure Security Engineer, SOC Analyst |\n| Windows Security | Advanced | MOD-21 | 5 | 22 | Infrastructure Security Engineer, SOC Analyst |\n| Identity & Access | Core | MOD-23 | 3 | 11 | Cybersecurity Engineer, Cloud Security Engineer |\n| Identity & Access | Advanced | MOD-24, MOD-25 | 8 | 32 | Cybersecurity Engineer, Cloud Security Engineer |\n| Cryptography | Core | MOD-26, MOD-27 | 8 | 27 | Cybersecurity Engineer |\n| Vulnerability Management | Advanced | MOD-28 | 7 | 32 | Cybersecurity Engineer, Infrastructure Security Engineer |\n| Application Security | Advanced | MOD-29, MOD-30, MOD-31 | 14 | 52 | DevSecOps Engineer, Cybersecurity Engineer |\n| SOC Operations | Core | MOD-32 | 5 | 17 | SOC Analyst, SOC Engineer, Security Operations Engineer |\n| SIEM & Logging | Core | MOD-33, MOD-34, MOD-35 | 16 | 60 | SOC Engineer, Security Platform Engineer |\n| Observability | Core | MOD-36 | 5 | 19 | Security Platform Engineer |\n| Endpoint Security | Core | MOD-37 | 5 | 24 | SOC Engineer, Incident Response Engineer |\n| Detection Engineering | Core | MOD-38, MOD-39 | 13 | 51 | Detection Engineer, Threat Detection Engineer |\n| Detection Engineering | Advanced | MOD-40 | 7 | 41 | Detection Engineer, Threat Detection Engineer |\n| Threat Intelligence | Advanced | MOD-41, MOD-42, MOD-43 | 10 | 38 | Threat Hunter, SOC Analyst |\n| Incident Response | Core | MOD-44, MOD-47 | 7 | 26 | Incident Response Engineer, SOC Analyst |\n| Incident Response | Advanced | MOD-45, MOD-46 | 11 | 47 | Incident Response Engineer, SOC Analyst |\n| Digital Forensics | Advanced | MOD-48 | 8 | 37 | Incident Response Engineer |\n| Threat Hunting | Advanced | MOD-49 | 12 | 47 | Threat Hunter |\n| Malware Analysis | Advanced | MOD-50 | 7 | 30 | Incident Response Engineer, Threat Hunter |\n| Cloud Security | Enterprise | MOD-51, MOD-52 | 10 | 40 | Cloud Security Engineer |\n| Container & Kubernetes Security | Advanced | MOD-53, MOD-54 | 9 | 36 | Cloud Security Engineer, DevSecOps Engineer |\n| DevSecOps | Advanced | MOD-55 | 6 | 28 | DevSecOps Engineer |\n| Security Automation | Advanced | MOD-57 | 8 | 35 | Security Automation Engineer |\n| SIEM & Logging | Enterprise | MOD-58 | 6 | 28 | SOC Engineer, Security Platform Engineer |\n| SOC Operations | Advanced | MOD-59, MOD-60, MOD-63, MOD-64 | 22 | 137 | SOC Analyst, SOC Engineer, Security Operations Engineer |\n| AI Security | Advanced | MOD-61 | 6 | 30 | Security Automation Engineer, Security Operations Engineer |\n| Security Architecture | Advanced | MOD-62 | 6 | 26 | Cybersecurity Engineer, Security Platform Engineer |\n| Career | Core | MOD-65 | 6 | 24 | Security Operations Engineer |",
   "parent": "Wiki"
  },
  {
   "title": "Tool_Matrix",
   "text": "# Tool matrix\n\n| Tier | Tool | Modules | Hours in those modules |\n|---|---|---|---|\n| Master | Linux | MOD-01, MOD-12, MOD-15 | 40 |\n| Master | Windows | MOD-01, MOD-17, MOD-22 | 50 |\n| Master | PowerShell | MOD-18, MOD-56 | 52 |\n| Master | Bash | MOD-16 | 22 |\n| Master | Python | MOD-56, MOD-57, MOD-61 | 104 |\n| Master | Wireshark | MOD-05, MOD-06, MOD-08 | 49 |\n| Master | Nmap | MOD-09, MOD-28 | 43 |\n| Master | Wazuh | MOD-01, MOD-33, MOD-34, MOD-35, MOD-37, MOD-40, MOD-46, MOD-49, MOD-63, MOD-64 | 329 |\n| Master | Sysmon | MOD-19, MOD-33, MOD-40, MOD-46, MOD-63, MOD-64 | 228 |\n| Master | Zeek | MOD-01, MOD-10, MOD-40, MOD-46, MOD-63, MOD-64 | 212 |\n| Master | Suricata | MOD-01, MOD-11, MOD-40, MOD-46, MOD-63, MOD-64 | 227 |\n| Master | Grafana | MOD-01, MOD-36, MOD-59, MOD-60, MOD-63, MOD-64 | 169 |\n| Master | Prometheus | MOD-36, MOD-59, MOD-60 | 46 |\n| Master | MITRE ATT&CK | MOD-04, MOD-38, MOD-64 | 122 |\n| Master | Sigma | MOD-39, MOD-40, MOD-49, MOD-64 | 184 |\n| Advanced | Velociraptor | MOD-37, MOD-48, MOD-49, MOD-63, MOD-64 | 218 |\n| Advanced | TheHive | MOD-45, MOD-46, MOD-57, MOD-63, MOD-64 | 192 |\n| Advanced | MISP | MOD-42, MOD-63, MOD-64 | 123 |\n| Advanced | OpenCTI | MOD-43 | 15 |\n| Advanced | YARA | MOD-50 | 30 |\n| Advanced | Volatility | MOD-48 | 37 |\n| Advanced | BloodHound | MOD-21 | 22 |\n| Advanced | Greenbone/OpenVAS | MOD-28, MOD-64 | 108 |\n| Advanced | Burp Suite | MOD-29, MOD-30, MOD-31 | 52 |\n| Advanced | Nuclei | MOD-28, MOD-30 | 52 |\n| Advanced | Trivy | MOD-53, MOD-54, MOD-55 | 64 |\n| Advanced | Falco | MOD-53, MOD-54 | 36 |\n| Advanced | OpenBao | MOD-25 | 12 |\n| Advanced | n8n | MOD-57, MOD-63, MOD-64 | 145 |\n| Enterprise | Microsoft Sentinel | MOD-58 | 28 |\n| Enterprise | Microsoft Defender | MOD-22, MOD-37, MOD-58 | 74 |\n| Enterprise | Microsoft Entra ID | MOD-24, MOD-52, MOD-58 | 64 |\n| Enterprise | Splunk | MOD-58 | 28 |\n| Enterprise | Elastic Security | MOD-58 | 28 |\n| Enterprise | AWS Security | MOD-51 | 24 |\n| Enterprise | Azure Security | MOD-52 | 16 |\n| Supporting | AbuseIPDB | MOD-41 | 10 |\n| Supporting | Active Directory | MOD-20, MOD-24 | 37 |\n| Supporting | AlienVault OTX | MOD-41 | 10 |\n| Supporting | AppArmor | MOD-14 | 19 |\n| Supporting | auditd | MOD-13, MOD-15, MOD-33, MOD-63 | 91 |\n| Supporting | Autopsy | MOD-48 | 37 |\n| Supporting | Autoruns | MOD-17 | 15 |\n| Supporting | capa | MOD-50 | 30 |\n| Supporting | ClickHouse | MOD-36 | 19 |\n| Supporting | Cortex | MOD-45, MOD-57 | 48 |\n| Supporting | curl | MOD-06, MOD-29, MOD-31 | 49 |\n| Supporting | dig | MOD-06 | 17 |\n| Supporting | Docker | MOD-53 | 15 |\n| Supporting | Docker Scout | MOD-53 | 15 |\n| Supporting | draw.io | MOD-62 | 26 |\n| Supporting | Elastic Defend | MOD-37 | 24 |\n| Supporting | Elasticsearch | MOD-36 | 19 |\n| Supporting | EQL | MOD-39, MOD-49 | 67 |\n| Supporting | Eric Zimmerman tools | MOD-48 | 37 |\n| Supporting | Event Viewer | MOD-17 | 15 |\n| Supporting | Fail2Ban | MOD-14 | 19 |\n| Supporting | ffuf | MOD-30 | 20 |\n| Supporting | Firewall | MOD-01, MOD-07 | 26 |\n| Supporting | FLARE-VM | MOD-50 | 30 |\n| Supporting | FreeIPA | MOD-24 | 20 |\n| Supporting | Ghidra | MOD-50 | 30 |\n| Supporting | Git | MOD-65 | 24 |\n| Supporting | GitLab | MOD-55 | 28 |\n| Supporting | Gitleaks | MOD-55 | 28 |\n| Supporting | Gobuster | MOD-30 | 20 |\n| Supporting | GPG | MOD-26 | 13 |\n| Supporting | Grafana Alloy | MOD-34, MOD-36 | 38 |\n| Supporting | Grype | MOD-53, MOD-55 | 43 |\n| Supporting | Hashcat | MOD-26 | 13 |\n| Supporting | htop | MOD-12 | 16 |\n| Supporting | iptables | MOD-14 | 19 |\n| Supporting | John the Ripper | MOD-26 | 13 |\n| Supporting | journalctl | MOD-13 | 17 |\n| Supporting | KAPE | MOD-48 | 37 |\n| Supporting | Keycloak | MOD-24 | 20 |\n| Supporting | KQL | MOD-39, MOD-49 | 67 |\n| Supporting | kube-bench | MOD-54 | 21 |\n| Supporting | Kubescape | MOD-54 | 21 |\n| Supporting | Kyverno | MOD-54 | 21 |\n| Supporting | Loki | MOD-36 | 19 |\n| Supporting | lsof | MOD-12 | 16 |\n| Supporting | Lynis | MOD-14, MOD-28 | 51 |\n| Supporting | Netcat | MOD-06 | 17 |\n| Supporting | nftables | MOD-14 | 19 |\n| Supporting | Nikto | MOD-30 | 20 |\n| Supporting | nslookup | MOD-06 | 17 |\n| Supporting | OPA Gatekeeper | MOD-54 | 21 |\n| Supporting | OpenSCAP | MOD-14, MOD-28 | 51 |\n| Supporting | OpenSearch | MOD-34, MOD-35, MOD-36 | 50 |\n| Supporting | OpenSSL | MOD-06, MOD-26, MOD-27 | 44 |\n| Supporting | OpenTelemetry | MOD-36 | 19 |\n| Supporting | osquery | MOD-37 | 24 |\n| Supporting | OWASP ZAP | MOD-29, MOD-30, MOD-55 | 62 |\n| Supporting | PostgreSQL | MOD-56 | 39 |\n| Supporting | Postman | MOD-29, MOD-31 | 32 |\n| Supporting | Process Explorer | MOD-17 | 15 |\n| Supporting | Process Monitor | MOD-17 | 15 |\n| Supporting | ps | MOD-12 | 16 |\n| Supporting | REMnux | MOD-50 | 30 |\n| Supporting | SELinux | MOD-14 | 19 |\n| Supporting | Semgrep | MOD-55 | 28 |\n| Supporting | SharpHound | MOD-21 | 22 |\n| Supporting | Shuffle | MOD-57 | 35 |\n| Supporting | Snort | MOD-11 | 29 |\n| Supporting | SPL | MOD-39, MOD-49 | 67 |\n| Supporting | SQL | MOD-39, MOD-49, MOD-56 | 106 |\n| Supporting | SQLite | MOD-56 | 39 |\n| Supporting | ss | MOD-12 | 16 |\n| Supporting | strace | MOD-12 | 16 |\n| Supporting | Syft | MOD-53, MOD-55 | 43 |\n| Supporting | syslog | MOD-13 | 17 |\n| Supporting | tcpdump | MOD-05, MOD-08 | 32 |\n| Supporting | TCPView | MOD-17 | 15 |\n| Supporting | ThreatFox | MOD-41 | 10 |\n| Supporting | top | MOD-12 | 16 |\n| Supporting | UFW | MOD-14 | 19 |\n| Supporting | URLhaus | MOD-41 | 10 |\n| Supporting | Vector | MOD-34, MOD-36 | 38 |\n| Supporting | VirusTotal | MOD-41, MOD-50 | 40 |\n| Supporting | x64dbg | MOD-50 | 30 |",
   "parent": "Wiki"
  },
  {
   "title": "Module_Guides",
   "text": "# Module guides\n\nOne page per module. The instructor writes the steps once here; every student's issue links to it.\n\n## Phase 01 - Cybersecurity Foundations\n\n- [[MOD-01]] Lab Environment\n- [[MOD-02]] Security Principles\n- [[MOD-03]] Risk, Controls and Governance\n- [[MOD-04]] Security Frameworks\n\n## Phase 02 - Networking & Network Security\n\n- [[MOD-05]] Network Fundamentals\n- [[MOD-06]] Core Network Protocols\n- [[MOD-07]] Network Security Architecture\n- [[MOD-08]] Wireshark and Packet Analysis\n- [[MOD-09]] Nmap and Network Discovery\n- [[MOD-10]] Zeek Network Security Monitoring\n- [[MOD-11]] Suricata IDS/IPS\n\n## Phase 03 - Linux Security\n\n- [[MOD-12]] Linux Internals for Security\n- [[MOD-13]] Linux Logging and Auditing\n- [[MOD-14]] Linux Hardening\n- [[MOD-15]] Linux Privilege and Persistence Review\n- [[MOD-16]] Bash for Security\n\n## Phase 04 - Windows & Active Directory Security\n\n- [[MOD-17]] Windows Internals for Security\n- [[MOD-18]] PowerShell for Security\n- [[MOD-19]] Sysmon\n- [[MOD-20]] Active Directory Fundamentals\n- [[MOD-21]] Active Directory Security\n- [[MOD-22]] Windows Hardening and Microsoft Defender\n\n## Phase 05 - IAM & Cryptography\n\n- [[MOD-23]] IAM Concepts\n- [[MOD-24]] Federation and Modern Authentication\n- [[MOD-25]] Secrets Management with OpenBao\n- [[MOD-26]] Cryptography Fundamentals\n- [[MOD-27]] PKI and TLS\n\n## Phase 06 - Vulnerability & Web Security\n\n- [[MOD-28]] Vulnerability Management\n- [[MOD-29]] Web Fundamentals and Browser Security Controls\n- [[MOD-30]] OWASP Top 10\n- [[MOD-31]] API Security\n\n## Phase 07 - SOC & SIEM\n\n- [[MOD-32]] SOC Engineering\n- [[MOD-33]] Wazuh\n- [[MOD-34]] SIEM Concepts and Log Pipeline\n- [[MOD-35]] Security Logging Investigations\n- [[MOD-36]] Security Observability\n- [[MOD-37]] EDR and XDR\n\n## Phase 08 - Detection Engineering\n\n- [[MOD-38]] MITRE ATT&CK\n- [[MOD-39]] Detection Engineering Fundamentals\n- [[MOD-40]] Detection Engineering Project\n\n## Phase 09 - Threat Intelligence\n\n- [[MOD-41]] Threat Intelligence Fundamentals\n- [[MOD-42]] MISP\n- [[MOD-43]] OpenCTI\n\n## Phase 10 - Incident Response & DFIR\n\n- [[MOD-44]] Incident Response Process\n- [[MOD-45]] Case Management with TheHive\n- [[MOD-46]] Incident Scenarios\n- [[MOD-47]] Email Security\n- [[MOD-48]] Digital Forensics\n\n## Phase 11 - Threat Hunting & Malware\n\n- [[MOD-49]] Threat Hunting\n- [[MOD-50]] Malware Analysis\n\n## Phase 12 - Cloud & DevSecOps\n\n- [[MOD-51]] AWS Security\n- [[MOD-52]] Azure Security\n- [[MOD-53]] Container Security\n- [[MOD-54]] Kubernetes Security\n- [[MOD-55]] DevSecOps Pipeline\n\n## Phase 13 - Security Automation\n\n- [[MOD-56]] Security Programming\n- [[MOD-57]] Security Automation and SOAR\n\n## Phase 14 - Advanced Security Engineering\n\n- [[MOD-58]] Enterprise SIEM and XDR Platforms\n- [[MOD-59]] Security Metrics\n- [[MOD-60]] SRE and Security\n- [[MOD-61]] AI for Cybersecurity\n- [[MOD-62]] Security Architecture\n\n## Phase 15 - Enterprise SOC Capstone\n\n- [[MOD-63]] Final Practical SOC Lab\n- [[MOD-64]] Capstone: Enterprise Security Operations Center\n- [[MOD-65]] Career Preparation\n",
   "parent": "Wiki"
  },
  {
   "title": "MOD-01",
   "text": "# MOD-01 Lab Environment\n\n**Phase:** 01 Cybersecurity Foundations | **Domain:** Foundations | **Skill level:** Foundation | **Environment:** Lab Network\n\n**Topics:** Lab network segments; Firewall; Linux server; Windows server; Endpoint agents; SIEM; Network sensors; Log pipeline; Dashboards; Cloud-based alternatives; Authorized-use rules\n\n**Tools:** Firewall; Linux; Windows; Wazuh; Zeek; Suricata; Grafana\n\n## THY-001 Lab architecture, sizing and authorized-use rules\n\n**Type:** Theory | **Estimated time:** 2 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-001 Build the lab network and firewall\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-002 Deploy the Linux and Windows lab servers\n\n**Type:** Lab | **Estimated time:** 5 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## DOC-001 Lab inventory and network diagram\n\n**Type:** Documentation | **Estimated time:** 2 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n",
   "parent": "Module_Guides"
  },
  {
   "title": "MOD-02",
   "text": "# MOD-02 Security Principles\n\n**Phase:** 01 Cybersecurity Foundations | **Domain:** Foundations | **Skill level:** Foundation | **Environment:** Workstation\n\n**Topics:** CIA Triad; AAA; Authentication; Authorization; Accounting; Least privilege; Defense in depth; Zero Trust; Security by design\n\n**Tools:** None\n\n## THY-002 CIA Triad, AAA and core design principles\n\n**Type:** Theory | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## ASG-001 Apply the principles to a sample company\n\n**Type:** Assignment | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n",
   "parent": "Module_Guides"
  },
  {
   "title": "MOD-03",
   "text": "# MOD-03 Risk, Controls and Governance\n\n**Phase:** 01 Cybersecurity Foundations | **Domain:** Foundations | **Skill level:** Foundation | **Environment:** Workstation\n\n**Topics:** Risk; Threat; Vulnerability; Attack surface; Security controls; Preventive controls; Detective controls; Corrective controls; Security governance; Security policies; Business continuity; Disaster recovery\n\n**Tools:** None\n\n## THY-003 Risk, threat, vulnerability and control types\n\n**Type:** Theory | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## ASG-002 Build a risk register and control map for the lab\n\n**Type:** Assignment | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## ASG-003 Write a business continuity and disaster recovery outline\n\n**Type:** Assignment | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n",
   "parent": "Module_Guides"
  },
  {
   "title": "MOD-04",
   "text": "# MOD-04 Security Frameworks\n\n**Phase:** 01 Cybersecurity Foundations | **Domain:** Foundations | **Skill level:** Foundation | **Environment:** Workstation\n\n**Topics:** NIST Cybersecurity Framework; NIST 800-53; NIST 800-61; CIS Controls; ISO 27001; MITRE ATT&CK; Cyber Kill Chain; OWASP; PCI DSS; SOC 2\n\n**Tools:** MITRE ATT&CK\n\n## THY-004 NIST CSF, NIST 800-53 and CIS Controls\n\n**Type:** Theory | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## THY-005 ISO 27001, PCI DSS and SOC 2\n\n**Type:** Theory | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## THY-006 MITRE ATT&CK, Cyber Kill Chain, NIST 800-61 and OWASP overview\n\n**Type:** Theory | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## ASG-004 Map three security incidents to the frameworks\n\n**Type:** Assignment | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## ASM-001 Phase 01 assessment: fundamentals and frameworks\n\n**Type:** Assessment | **Estimated time:** 2 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n",
   "parent": "Module_Guides"
  },
  {
   "title": "MOD-05",
   "text": "# MOD-05 Network Fundamentals\n\n**Phase:** 02 Networking & Network Security | **Domain:** Network Security | **Skill level:** Core | **Environment:** Lab Network\n\n**Topics:** OSI model; TCP/IP; Ethernet; IPv4; IPv6; Subnetting; CIDR; VLAN; ARP; ICMP; Routing; NAT\n\n**Tools:** tcpdump; Wireshark\n\n## THY-007 OSI and TCP/IP models, Ethernet, IPv4 and IPv6\n\n**Type:** Theory | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-003 Subnetting, CIDR and the lab addressing plan\n\n**Type:** Lab | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-004 Observe ARP, ICMP, routing and NAT with tcpdump\n\n**Type:** Lab | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-005 VLANs and segmentation in the lab\n\n**Type:** Lab | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n",
   "parent": "Module_Guides"
  },
  {
   "title": "MOD-06",
   "text": "# MOD-06 Core Network Protocols\n\n**Phase:** 02 Networking & Network Security | **Domain:** Network Security | **Skill level:** Core | **Environment:** Lab Network\n\n**Topics:** TCP; UDP; DNS; DHCP; HTTP; HTTPS; TLS; SSH; FTP/SFTP; SMTP; SNMP; LDAP; Kerberos; SMB; RDP; NTP\n\n**Tools:** Wireshark; dig; nslookup; curl; OpenSSL; Netcat\n\n## THY-008 Transport and application protocols for defenders\n\n**Type:** Theory | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-006 TCP and UDP behaviour in packet captures\n\n**Type:** Lab | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-007 DNS and DHCP with dig and nslookup\n\n**Type:** Lab | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-008 HTTP, HTTPS and TLS with curl and OpenSSL\n\n**Type:** Lab | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-009 Identify SSH, SMTP, SNMP, LDAP, Kerberos, SMB, RDP and NTP traffic\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n",
   "parent": "Module_Guides"
  },
  {
   "title": "MOD-07",
   "text": "# MOD-07 Network Security Architecture\n\n**Phase:** 02 Networking & Network Security | **Domain:** Network Security | **Skill level:** Core | **Environment:** Lab Network\n\n**Topics:** Firewall; NAT; VPN; Proxy; Reverse proxy; Load balancing; WAF; IDS; IPS; Network segmentation; DMZ; Zero Trust networking\n\n**Tools:** Firewall\n\n## THY-009 Firewalls, VPN, proxies, WAF, IDS and IPS\n\n**Type:** Theory | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-010 Firewall policy and DMZ for the lab\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-011 VPN and reverse proxy in the lab\n\n**Type:** Lab | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## ASG-005 Segmentation and Zero Trust network design\n\n**Type:** Assignment | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n",
   "parent": "Module_Guides"
  },
  {
   "title": "MOD-08",
   "text": "# MOD-08 Wireshark and Packet Analysis\n\n**Phase:** 02 Networking & Network Security | **Domain:** Network Security | **Skill level:** Core | **Environment:** Lab Network\n\n**Topics:** Packet analysis; Display and capture filters; TCP investigation; DNS investigation; HTTP investigation; TLS analysis; Suspicious traffic investigation\n\n**Tools:** Wireshark; tcpdump\n\n## LAB-012 Wireshark profiles, filters and statistics\n\n**Type:** Lab | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-013 Analyze TCP Traffic with Wireshark\n\n**Type:** Lab | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## INV-001 PCAP investigation: DNS anomalies\n\n**Type:** Investigation | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## INV-002 PCAP investigation: HTTP session reconstruction\n\n**Type:** Investigation | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## INV-003 PCAP investigation: TLS and certificate anomalies\n\n**Type:** Investigation | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## INV-004 PCAP investigation: suspicious outbound traffic\n\n**Type:** Investigation | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n",
   "parent": "Module_Guides"
  },
  {
   "title": "MOD-09",
   "text": "# MOD-09 Nmap and Network Discovery\n\n**Phase:** 02 Networking & Network Security | **Domain:** Network Security | **Skill level:** Core | **Environment:** Lab Network\n\n**Topics:** Host discovery; Port states; Service and version detection; Scripting engine; Asset inventory; Scan visibility for defenders\n\n**Tools:** Nmap\n\n## LAB-014 Host discovery and port scanning of the lab\n\n**Type:** Lab | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-015 Service detection and Nmap scripts for asset inventory\n\n**Type:** Lab | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## INV-005 See a scan from the defender side in captures and firewall logs\n\n**Type:** Investigation | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## ASG-006 Asset inventory of the lab from scan results\n\n**Type:** Assignment | **Estimated time:** 2 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n",
   "parent": "Module_Guides"
  },
  {
   "title": "MOD-10",
   "text": "# MOD-10 Zeek Network Security Monitoring\n\n**Phase:** 02 Networking & Network Security | **Domain:** Network Security | **Skill level:** Core | **Environment:** Lab Network\n\n**Topics:** Network metadata; Connections; DNS; HTTP; TLS; Files; Protocol analysis; Zeek logs\n\n**Tools:** Zeek\n\n## LAB-016 Install Zeek on the network sensor\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-017 Read conn, dns, http, ssl and files logs\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-018 Detect Port Scanning with Zeek\n\n**Type:** Lab | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## INV-006 Investigate a session end to end with Zeek logs\n\n**Type:** Investigation | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n",
   "parent": "Module_Guides"
  },
  {
   "title": "MOD-11",
   "text": "# MOD-11 Suricata IDS/IPS\n\n**Phase:** 02 Networking & Network Security | **Domain:** Network Security | **Skill level:** Core | **Environment:** Lab Network\n\n**Topics:** IDS; IPS; Signatures; Rules; Alerts; Protocol inspection; Snort comparison\n\n**Tools:** Suricata; Snort\n\n## LAB-019 Install Suricata in IDS mode with a rule set\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-020 Read alerts and protocol events\n\n**Type:** Lab | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-021 Write and test custom Suricata rules\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-022 Run Suricata inline as IPS\n\n**Type:** Lab | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## INV-007 Correlate Suricata alerts with Zeek logs and packet captures\n\n**Type:** Investigation | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## PROJECT-001 Network security monitoring sensor\n\n**Type:** Project | **Estimated time:** 8 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## ASM-002 Phase 02 assessment: PCAP analysis practical\n\n**Type:** Assessment | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n",
   "parent": "Module_Guides"
  },
  {
   "title": "MOD-12",
   "text": "# MOD-12 Linux Internals for Security\n\n**Phase:** 03 Linux Security | **Domain:** Linux Security | **Skill level:** Core | **Environment:** Linux Server\n\n**Topics:** Linux architecture; Users; Groups; Permissions; ACL; sudo; PAM; Processes; Services; systemd; Cron\n\n**Tools:** Linux; ps; top; htop; ss; lsof; strace\n\n## THY-010 Linux architecture, identities and permissions\n\n**Type:** Theory | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-023 Audit users, groups, permissions, ACLs and sudo\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-024 PAM password and lockout policy\n\n**Type:** Lab | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-025 Inspect processes, services and sockets\n\n**Type:** Lab | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-026 Review cron and systemd units\n\n**Type:** Lab | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n",
   "parent": "Module_Guides"
  },
  {
   "title": "MOD-13",
   "text": "# MOD-13 Linux Logging and Auditing\n\n**Phase:** 03 Linux Security | **Domain:** Linux Security | **Skill level:** Core | **Environment:** Linux Server\n\n**Topics:** Logs; journald; syslog; auditd; File integrity; Authentication logs\n\n**Tools:** journalctl; auditd; syslog\n\n## LAB-027 journald and syslog with remote forwarding\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-028 auditd rules for identity, privilege and file changes\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## INV-008 Investigate SSH authentication logs\n\n**Type:** Investigation | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## INV-009 Investigate sudo activity with auditd\n\n**Type:** Investigation | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-029 File integrity monitoring\n\n**Type:** Lab | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n",
   "parent": "Module_Guides"
  },
  {
   "title": "MOD-14",
   "text": "# MOD-14 Linux Hardening\n\n**Phase:** 03 Linux Security | **Domain:** Linux Security | **Skill level:** Core | **Environment:** Linux Server\n\n**Topics:** SSH hardening; Host firewall; Kernel security; SELinux; AppArmor; Linux capabilities; Namespaces; Containers; Benchmarks\n\n**Tools:** iptables; nftables; UFW; Fail2Ban; Lynis; OpenSCAP; SELinux; AppArmor\n\n## LAB-030 SSH hardening\n\n**Type:** Lab | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-031 Host firewall with nftables or UFW and Fail2Ban\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-032 SELinux and AppArmor in enforcing mode\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-033 Kernel parameters, capabilities and namespaces\n\n**Type:** Lab | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-034 Benchmark scan with Lynis and OpenSCAP and remediation\n\n**Type:** Lab | **Estimated time:** 5 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n",
   "parent": "Module_Guides"
  },
  {
   "title": "MOD-15",
   "text": "# MOD-15 Linux Privilege and Persistence Review\n\n**Phase:** 03 Linux Security | **Domain:** Linux Security | **Skill level:** Core | **Environment:** Linux Server\n\n**Topics:** Privilege escalation concepts; Misconfiguration review; Persistence locations; Host triage\n\n**Tools:** Linux; auditd\n\n## THY-011 Privilege escalation concepts and common misconfigurations\n\n**Type:** Theory | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-035 Review a host for privilege and persistence misconfigurations\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## INV-010 Triage a Linux host from logs and system state\n\n**Type:** Investigation | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n",
   "parent": "Module_Guides"
  },
  {
   "title": "MOD-16",
   "text": "# MOD-16 Bash for Security\n\n**Phase:** 03 Linux Security | **Domain:** Security Programming | **Skill level:** Core | **Environment:** Linux Server\n\n**Topics:** Shell scripting; Log parsing; Automation; Cron; systemd\n\n**Tools:** Bash\n\n## LAB-036 Bash scripting fundamentals\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-037 Log parsing with grep, awk, sed and jq\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-038 Scheduled collection script with cron or systemd timers\n\n**Type:** Lab | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## PROJECT-002 Build Linux Security Monitoring\n\n**Type:** Project | **Estimated time:** 8 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## ASM-003 Phase 03 assessment: Linux security practical\n\n**Type:** Assessment | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n",
   "parent": "Module_Guides"
  },
  {
   "title": "MOD-17",
   "text": "# MOD-17 Windows Internals for Security\n\n**Phase:** 04 Windows & Active Directory Security | **Domain:** Windows Security | **Skill level:** Core | **Environment:** Windows Domain\n\n**Topics:** Windows architecture; Windows services; Registry; Windows Event Logs; Windows authentication; NTLM; Kerberos\n\n**Tools:** Windows; Event Viewer; Autoruns; Process Explorer; Process Monitor; TCPView\n\n## THY-012 Windows architecture, services, registry and authentication\n\n**Type:** Theory | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-039 Sysinternals: Autoruns, Process Explorer, Process Monitor and TCPView\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-040 Windows Event Logs and audit policy\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-041 Registry and service review\n\n**Type:** Lab | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n",
   "parent": "Module_Guides"
  },
  {
   "title": "MOD-18",
   "text": "# MOD-18 PowerShell for Security\n\n**Phase:** 04 Windows & Active Directory Security | **Domain:** Security Programming | **Skill level:** Core | **Environment:** Windows Domain\n\n**Topics:** PowerShell; Event logs; Windows security; Automation; PowerShell logging\n\n**Tools:** PowerShell\n\n## LAB-042 PowerShell fundamentals\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-043 Query event logs with PowerShell\n\n**Type:** Lab | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-044 Enable and review PowerShell logging\n\n**Type:** Lab | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-045 Collection script in PowerShell\n\n**Type:** Lab | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n",
   "parent": "Module_Guides"
  },
  {
   "title": "MOD-19",
   "text": "# MOD-19 Sysmon\n\n**Phase:** 04 Windows & Active Directory Security | **Domain:** Windows Security | **Skill level:** Core | **Environment:** Windows Domain\n\n**Topics:** Endpoint telemetry; Process creation; Network connections; File and registry events; Configuration tuning\n\n**Tools:** Sysmon\n\n## LAB-046 Deploy Sysmon with a configuration\n\n**Type:** Lab | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-047 Read and filter Sysmon events\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-048 Tune the Sysmon configuration\n\n**Type:** Lab | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## INV-011 Investigate a process tree with Sysmon\n\n**Type:** Investigation | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n",
   "parent": "Module_Guides"
  },
  {
   "title": "MOD-20",
   "text": "# MOD-20 Active Directory Fundamentals\n\n**Phase:** 04 Windows & Active Directory Security | **Domain:** Windows Security | **Skill level:** Core | **Environment:** Windows Domain\n\n**Topics:** AD architecture; Domains; Forests; Trusts; OU; GPO; Users; Groups; Computers; Domain Controllers; DNS; LDAP; Kerberos; NTLM; SPNs; Delegation; Service accounts\n\n**Tools:** Active Directory\n\n## THY-013 Active Directory architecture and authentication\n\n**Type:** Theory | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-049 Build the lab domain with OUs, users, groups and GPOs\n\n**Type:** Lab | **Estimated time:** 5 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-050 Kerberos, NTLM, SPNs and delegation in the lab\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-051 Domain controller auditing and key event IDs\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n",
   "parent": "Module_Guides"
  },
  {
   "title": "MOD-21",
   "text": "# MOD-21 Active Directory Security\n\n**Phase:** 04 Windows & Active Directory Security | **Domain:** Windows Security | **Skill level:** Advanced | **Environment:** Windows Domain\n\n**Topics:** Kerberoasting; AS-REP roasting; Pass-the-Hash; Pass-the-Ticket; Credential dumping; Lateral movement; AD hardening; Attack paths\n\n**Tools:** BloodHound; SharpHound\n\n## THY-014 Active Directory security scenarios and how they appear in logs\n\n**Type:** Theory | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-052 Map lab AD relationships with BloodHound\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## INV-012 Detect and investigate Kerberos ticket abuse\n\n**Type:** Investigation | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## INV-013 Detect and investigate credential misuse and lateral movement\n\n**Type:** Investigation | **Estimated time:** 5 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-053 AD hardening\n\n**Type:** Lab | **Estimated time:** 5 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n",
   "parent": "Module_Guides"
  },
  {
   "title": "MOD-22",
   "text": "# MOD-22 Windows Hardening and Microsoft Defender\n\n**Phase:** 04 Windows & Active Directory Security | **Domain:** Windows Security | **Skill level:** Core | **Environment:** Windows Domain\n\n**Topics:** Microsoft Defender; Group Policy baselines; Privilege escalation; Persistence; Lateral movement; SMB; RDP\n\n**Tools:** Microsoft Defender; Windows\n\n## LAB-054 Microsoft Defender Antivirus configuration and logs\n\n**Type:** Lab | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-055 Hardening baseline through Group Policy\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## INV-014 Review a Windows host for persistence\n\n**Type:** Investigation | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## PROJECT-003 Windows and Active Directory security monitoring baseline\n\n**Type:** Project | **Estimated time:** 8 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## ASM-004 Phase 04 assessment: Windows and AD practical\n\n**Type:** Assessment | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n",
   "parent": "Module_Guides"
  },
  {
   "title": "MOD-23",
   "text": "# MOD-23 IAM Concepts\n\n**Phase:** 05 IAM & Cryptography | **Domain:** Identity & Access | **Skill level:** Core | **Environment:** Workstation\n\n**Topics:** IAM; Authentication; Authorization; MFA; SSO; RBAC; ABAC; PAM; JIT access; JEA; Service accounts; Password policies\n\n**Tools:** None\n\n## THY-015 IAM, MFA, SSO, RBAC, ABAC and privileged access\n\n**Type:** Theory | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## ASG-007 Design an RBAC model for the lab organisation\n\n**Type:** Assignment | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-056 Just-enough and just-in-time administration\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n",
   "parent": "Module_Guides"
  },
  {
   "title": "MOD-24",
   "text": "# MOD-24 Federation and Modern Authentication\n\n**Phase:** 05 IAM & Cryptography | **Domain:** Identity & Access | **Skill level:** Advanced | **Environment:** Lab Network\n\n**Topics:** Federation; OAuth 2.0; OpenID Connect; SAML; Kerberos; LDAP; SSO\n\n**Tools:** Keycloak; FreeIPA; Microsoft Entra ID; Active Directory\n\n## THY-016 OAuth 2.0, OpenID Connect and SAML\n\n**Type:** Theory | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-057 Single sign-on with Keycloak and MFA\n\n**Type:** Lab | **Estimated time:** 5 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-058 Trace an OpenID Connect and a SAML sign-in\n\n**Type:** Lab | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-059 Central Linux identity with FreeIPA\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-060 Microsoft Entra ID tenant basics\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n",
   "parent": "Module_Guides"
  },
  {
   "title": "MOD-25",
   "text": "# MOD-25 Secrets Management with OpenBao\n\n**Phase:** 05 IAM & Cryptography | **Domain:** Identity & Access | **Skill level:** Advanced | **Environment:** Lab Network\n\n**Topics:** Secrets management; Policies; Authentication methods; Dynamic secrets; Audit\n\n**Tools:** OpenBao\n\n## LAB-061 Install OpenBao and store secrets\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-062 Policies and authentication methods\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-063 Dynamic secrets and audit log\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n",
   "parent": "Module_Guides"
  },
  {
   "title": "MOD-26",
   "text": "# MOD-26 Cryptography Fundamentals\n\n**Phase:** 05 IAM & Cryptography | **Domain:** Cryptography | **Skill level:** Core | **Environment:** Workstation\n\n**Topics:** Symmetric encryption; AES; Asymmetric encryption; RSA; ECC; Hashing; SHA-256; SHA-3; HMAC; Digital signatures; Key exchange; Key management; Password hashing; Salting; Nonces\n\n**Tools:** OpenSSL; GPG; Hashcat; John the Ripper\n\n## THY-017 Symmetric, asymmetric, hashing and signatures\n\n**Type:** Theory | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-064 OpenSSL: encrypt, hash, HMAC and sign\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-065 GPG: sign and encrypt\n\n**Type:** Lab | **Estimated time:** 2 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-066 Password hashing strength audit on lab accounts\n\n**Type:** Lab | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n",
   "parent": "Module_Guides"
  },
  {
   "title": "MOD-27",
   "text": "# MOD-27 PKI and TLS\n\n**Phase:** 05 IAM & Cryptography | **Domain:** Cryptography | **Skill level:** Core | **Environment:** Lab Network\n\n**Topics:** Certificates; PKI; Certificate authorities; Certificate chains; TLS; Key exchange\n\n**Tools:** OpenSSL\n\n## LAB-067 Build a two-tier lab certificate authority\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-068 Deploy and test TLS on a lab service\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## INV-015 Investigate a certificate validation failure\n\n**Type:** Investigation | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## ASM-005 Phase 05 assessment: IAM and cryptography\n\n**Type:** Assessment | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n",
   "parent": "Module_Guides"
  },
  {
   "title": "MOD-28",
   "text": "# MOD-28 Vulnerability Management\n\n**Phase:** 06 Vulnerability & Web Security | **Domain:** Vulnerability Management | **Skill level:** Advanced | **Environment:** Lab Network\n\n**Topics:** Vulnerability management lifecycle; CVE; CVSS; CWE; CPE; Exploitation; Zero-days; Risk rating; Asset inventory; Patch management; Remediation; Compensating controls; Nessus concepts; Qualys concepts\n\n**Tools:** Greenbone/OpenVAS; Nmap; Nuclei; Lynis; OpenSCAP\n\n## THY-018 Vulnerability management lifecycle and scoring\n\n**Type:** Theory | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-069 Deploy Greenbone and scan the lab\n\n**Type:** Lab | **Estimated time:** 5 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-070 Authenticated scans and triage by risk\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-071 Template-based checks with Nuclei on lab targets\n\n**Type:** Lab | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-072 Remediate findings and rescan\n\n**Type:** Lab | **Estimated time:** 5 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## ASG-008 Vulnerability management policy and SLA\n\n**Type:** Assignment | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## PROJECT-004 Vulnerability management programme for the lab\n\n**Type:** Project | **Estimated time:** 8 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n",
   "parent": "Module_Guides"
  },
  {
   "title": "MOD-29",
   "text": "# MOD-29 Web Fundamentals and Browser Security Controls\n\n**Phase:** 06 Vulnerability & Web Security | **Domain:** Application Security | **Skill level:** Advanced | **Environment:** Lab Network\n\n**Topics:** HTTP; Cookies; Sessions; JWT; CORS; CSRF; CSP; Security headers; Authorized training environments only\n\n**Tools:** Burp Suite; OWASP ZAP; Postman; curl\n\n## THY-019 HTTP, sessions, cookies and tokens\n\n**Type:** Theory | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-073 Set up the authorized training application and an intercepting proxy\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-074 Sessions, cookies and JWT inspection\n\n**Type:** Lab | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-075 Security headers, CORS and CSP\n\n**Type:** Lab | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n",
   "parent": "Module_Guides"
  },
  {
   "title": "MOD-30",
   "text": "# MOD-30 OWASP Top 10\n\n**Phase:** 06 Vulnerability & Web Security | **Domain:** Application Security | **Skill level:** Advanced | **Environment:** Lab Network\n\n**Topics:** Broken access control; Cryptographic failures; Injection; XSS; SSRF; Security misconfiguration; Authentication failures; Supply-chain risks; Logging failures; SQL injection; Command injection; File upload security; Authorized training environments only\n\n**Tools:** Burp Suite; OWASP ZAP; Nikto; ffuf; Gobuster; Nuclei\n\n## THY-020 OWASP Top 10 categories and their controls\n\n**Type:** Theory | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-076 Access control and authentication weaknesses in the training application\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-077 Injection and XSS in the training application and their fixes\n\n**Type:** Lab | **Estimated time:** 5 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-078 SSRF, misconfiguration and file upload in the training application\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-079 Scan the training application with OWASP ZAP\n\n**Type:** Lab | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n",
   "parent": "Module_Guides"
  },
  {
   "title": "MOD-31",
   "text": "# MOD-31 API Security\n\n**Phase:** 06 Vulnerability & Web Security | **Domain:** Application Security | **Skill level:** Advanced | **Environment:** Lab Network\n\n**Topics:** API security; API authentication; API authorization; Logging failures; WAF\n\n**Tools:** Postman; curl; Burp Suite\n\n## THY-021 API security risks and controls\n\n**Type:** Theory | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-080 Test API authentication and authorization in the training application\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-081 Protect the training application with a WAF\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## INV-016 Investigate web server and WAF logs\n\n**Type:** Investigation | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## ASM-006 Phase 06 assessment: vulnerability and web security practical\n\n**Type:** Assessment | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n",
   "parent": "Module_Guides"
  },
  {
   "title": "MOD-32",
   "text": "# MOD-32 SOC Engineering\n\n**Phase:** 07 SOC & SIEM | **Domain:** SOC Operations | **Skill level:** Core | **Environment:** SOC Stack\n\n**Topics:** SOC architecture; SOC roles; L1 analyst; L2 analyst; L3 analyst; Security Engineer; Incident Responder; Threat Hunter; Detection Engineer; Alert triage; Alert enrichment; Incident classification; Escalation; Investigation; Evidence collection; Containment; Eradication; Recovery; Lessons learned\n\n**Tools:** None\n\n## THY-022 SOC architecture and roles\n\n**Type:** Theory | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## THY-023 Alert triage, classification and escalation\n\n**Type:** Theory | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## ASG-009 Write the SOC triage procedure\n\n**Type:** Assignment | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## INV-017 SOC ticket set 1: triage five alerts\n\n**Type:** Investigation | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## INV-018 SOC ticket set 2: escalated investigation\n\n**Type:** Investigation | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n",
   "parent": "Module_Guides"
  },
  {
   "title": "MOD-33",
   "text": "# MOD-33 Wazuh\n\n**Phase:** 07 SOC & SIEM | **Domain:** SIEM & Logging | **Skill level:** Core | **Environment:** SOC Stack\n\n**Topics:** Log collection; Agents; Decoders; Rules; Alerting; File integrity; Configuration assessment; Active response\n\n**Tools:** Wazuh; Sysmon; auditd\n\n## LAB-082 Deploy the Wazuh server, indexer and dashboard\n\n**Type:** Lab | **Estimated time:** 5 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-083 Enrol Linux and Windows agents with auditd and Sysmon\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-084 Decoders and rules\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-085 Detect Brute Force with Wazuh\n\n**Type:** Lab | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-086 File integrity, configuration assessment and vulnerability detection\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-087 Active response\n\n**Type:** Lab | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-088 Ingest Zeek and Suricata logs\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## TSH-001 Wazuh agent not reporting\n\n**Type:** Troubleshooting | **Estimated time:** 2 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n",
   "parent": "Module_Guides"
  },
  {
   "title": "MOD-34",
   "text": "# MOD-34 SIEM Concepts and Log Pipeline\n\n**Phase:** 07 SOC & SIEM | **Domain:** SIEM & Logging | **Skill level:** Core | **Environment:** SOC Stack\n\n**Topics:** Log collection; Log parsing; Normalization; Enrichment; Correlation; Searching; Indexing; Retention; Alerting; Detection rules; Dashboards; Threat intelligence integration\n\n**Tools:** Wazuh; OpenSearch; Vector; Grafana Alloy\n\n## THY-024 SIEM data flow from collection to alert\n\n**Type:** Theory | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-089 Build the log pipeline\n\n**Type:** Lab | **Estimated time:** 5 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-090 Parsing and normalization\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-091 Enrichment\n\n**Type:** Lab | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-092 Retention and index lifecycle\n\n**Type:** Lab | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n",
   "parent": "Module_Guides"
  },
  {
   "title": "MOD-35",
   "text": "# MOD-35 Security Logging Investigations\n\n**Phase:** 07 SOC & SIEM | **Domain:** SIEM & Logging | **Skill level:** Core | **Environment:** SOC Stack\n\n**Topics:** Linux: SSH, sudo, authentication, auditd, system, application, web server and database logs; Windows: Security, System, Application, PowerShell, Sysmon, Defender and Active Directory logs; Network: firewall, DNS, DHCP, VPN, proxy, IDS/IPS, NetFlow and Zeek logs\n\n**Tools:** Wazuh; OpenSearch\n\n## INV-019 Linux log investigation\n\n**Type:** Investigation | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## INV-020 Windows log investigation\n\n**Type:** Investigation | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## INV-021 Network log investigation\n\n**Type:** Investigation | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n",
   "parent": "Module_Guides"
  },
  {
   "title": "MOD-36",
   "text": "# MOD-36 Security Observability\n\n**Phase:** 07 SOC & SIEM | **Domain:** Observability | **Skill level:** Core | **Environment:** SOC Stack\n\n**Topics:** Logs; Metrics; Traces; Events; Labels; Metadata; Pipelines; Parsing; Enrichment; Retention; Aggregation; Alerting\n\n**Tools:** Grafana; Prometheus; Grafana Alloy; Vector; Loki; OpenTelemetry; OpenSearch; Elasticsearch; ClickHouse\n\n## THY-025 Logs, metrics, traces and events\n\n**Type:** Theory | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-093 Prometheus for the security infrastructure\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-094 Loki and collectors\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-095 Security dashboards in Grafana\n\n**Type:** Lab | **Estimated time:** 5 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-096 Alerting from Grafana and Prometheus\n\n**Type:** Lab | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n",
   "parent": "Module_Guides"
  },
  {
   "title": "MOD-37",
   "text": "# MOD-37 EDR and XDR\n\n**Phase:** 07 SOC & SIEM | **Domain:** Endpoint Security | **Skill level:** Core | **Environment:** SOC Stack\n\n**Topics:** Endpoint telemetry; Process monitoring; File monitoring; Registry monitoring; Network connections; Behavioral detection; Malware detection; Persistence; Endpoint isolation\n\n**Tools:** Wazuh; osquery; Velociraptor; Microsoft Defender; Elastic Defend\n\n## THY-026 Endpoint telemetry and behavioural detection\n\n**Type:** Theory | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-097 Endpoint queries with osquery\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-098 Endpoint response and isolation in the lab\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## PROJECT-005 Build SOC Monitoring Stack\n\n**Type:** Project | **Estimated time:** 10 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## ASM-007 Phase 07 assessment: SIEM investigation practical\n\n**Type:** Assessment | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n",
   "parent": "Module_Guides"
  },
  {
   "title": "MOD-38",
   "text": "# MOD-38 MITRE ATT&CK\n\n**Phase:** 08 Detection Engineering | **Domain:** Detection Engineering | **Skill level:** Core | **Environment:** SOC Stack\n\n**Topics:** Reconnaissance; Resource Development; Initial Access; Execution; Persistence; Privilege Escalation; Defense Evasion; Credential Access; Discovery; Lateral Movement; Collection; Command and Control; Exfiltration; Impact; Technique to scenario to evidence to detection to mitigation\n\n**Tools:** MITRE ATT&CK\n\n## THY-027 ATT&CK structure, tactics, techniques and data sources\n\n**Type:** Theory | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## ASG-010 Technique sheets: Reconnaissance, Resource Development and Initial Access\n\n**Type:** Assignment | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## ASG-011 Technique sheets: Execution and Persistence\n\n**Type:** Assignment | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## ASG-012 Technique sheets: Privilege Escalation and Defense Evasion\n\n**Type:** Assignment | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## ASG-013 Technique sheets: Credential Access and Discovery\n\n**Type:** Assignment | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## ASG-014 Technique sheets: Lateral Movement and Collection\n\n**Type:** Assignment | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## ASG-015 Technique sheets: Command and Control, Exfiltration and Impact\n\n**Type:** Assignment | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## ASG-016 Coverage heat map of the lab\n\n**Type:** Assignment | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n",
   "parent": "Module_Guides"
  },
  {
   "title": "MOD-39",
   "text": "# MOD-39 Detection Engineering Fundamentals\n\n**Phase:** 08 Detection Engineering | **Domain:** Detection Engineering | **Skill level:** Core | **Environment:** SOC Stack\n\n**Topics:** Detection lifecycle; Detection logic; False positives; Detection tuning; Rule testing; Alert severity; Detection coverage; MITRE mapping; Threat hunting queries; Detection-as-code\n\n**Tools:** Sigma; KQL; SPL; EQL; SQL\n\n## THY-028 Detection lifecycle and quality\n\n**Type:** Theory | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-099 Write Sigma rules and convert them\n\n**Type:** Lab | **Estimated time:** 5 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-100 The same logic in KQL, SPL, EQL and SQL\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-101 Test and tune detections\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-102 Detection-as-code repository\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n",
   "parent": "Module_Guides"
  },
  {
   "title": "MOD-40",
   "text": "# MOD-40 Detection Engineering Project\n\n**Phase:** 08 Detection Engineering | **Domain:** Detection Engineering | **Skill level:** Advanced | **Environment:** SOC Stack\n\n**Topics:** Twenty-five realistic detections with ATT&CK mapping, test evidence, tuning notes and severity\n\n**Tools:** Sigma; Wazuh; Zeek; Suricata; Sysmon\n\n## LAB-103 Detection pack 1: Windows endpoint\n\n**Type:** Lab | **Estimated time:** 6 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-104 Detection pack 2: identity and Active Directory\n\n**Type:** Lab | **Estimated time:** 6 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-105 Detection pack 3: Linux\n\n**Type:** Lab | **Estimated time:** 6 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-106 Detection pack 4: network\n\n**Type:** Lab | **Estimated time:** 6 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-107 Detection pack 5: web and cloud\n\n**Type:** Lab | **Estimated time:** 6 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## PROJECT-006 Detection engineering project: coverage, documentation and metrics\n\n**Type:** Project | **Estimated time:** 8 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## ASM-008 Phase 08 assessment: detection writing practical\n\n**Type:** Assessment | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n",
   "parent": "Module_Guides"
  },
  {
   "title": "MOD-41",
   "text": "# MOD-41 Threat Intelligence Fundamentals\n\n**Phase:** 09 Threat Intelligence | **Domain:** Threat Intelligence | **Skill level:** Advanced | **Environment:** SOC Stack\n\n**Topics:** IOC; IOA; TTP; Threat actors; Campaigns; Malware families; Threat feeds; Indicator enrichment; Threat intelligence lifecycle\n\n**Tools:** VirusTotal; AbuseIPDB; AlienVault OTX; URLhaus; ThreatFox\n\n## THY-029 Indicators, behaviours and the intelligence lifecycle\n\n**Type:** Theory | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## ASG-017 Threat actor profile mapped to ATT&CK\n\n**Type:** Assignment | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-108 Indicator enrichment from public sources\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n",
   "parent": "Module_Guides"
  },
  {
   "title": "MOD-42",
   "text": "# MOD-42 MISP\n\n**Phase:** 09 Threat Intelligence | **Domain:** Threat Intelligence | **Skill level:** Advanced | **Environment:** SOC Stack\n\n**Topics:** Events; Attributes; Feeds; Taxonomies; Sharing; Integration with detection\n\n**Tools:** MISP\n\n## LAB-109 Deploy MISP\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-110 Events, attributes, feeds and taxonomies\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-111 Feed indicators into Wazuh, Zeek and Suricata\n\n**Type:** Lab | **Estimated time:** 5 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n",
   "parent": "Module_Guides"
  },
  {
   "title": "MOD-43",
   "text": "# MOD-43 OpenCTI\n\n**Phase:** 09 Threat Intelligence | **Domain:** Threat Intelligence | **Skill level:** Advanced | **Environment:** SOC Stack\n\n**Topics:** Knowledge graph; STIX; Connectors; Campaign modelling\n\n**Tools:** OpenCTI\n\n## LAB-112 Deploy OpenCTI with connectors\n\n**Type:** Lab | **Estimated time:** 5 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-113 Model a campaign\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## INV-022 Intelligence-driven investigation\n\n**Type:** Investigation | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## ASM-009 Phase 09 assessment: threat intelligence\n\n**Type:** Assessment | **Estimated time:** 2 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n",
   "parent": "Module_Guides"
  },
  {
   "title": "MOD-44",
   "text": "# MOD-44 Incident Response Process\n\n**Phase:** 10 Incident Response & DFIR | **Domain:** Incident Response | **Skill level:** Core | **Environment:** SOC Stack\n\n**Topics:** Preparation; Identification; Containment; Eradication; Recovery; Lessons Learned; NIST 800-61; Playbooks\n\n**Tools:** None\n\n## THY-030 The incident response lifecycle\n\n**Type:** Theory | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## ASG-018 Incident response plan and communication matrix\n\n**Type:** Assignment | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## DOC-002 Incident response playbooks\n\n**Type:** Documentation | **Estimated time:** 5 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n",
   "parent": "Module_Guides"
  },
  {
   "title": "MOD-45",
   "text": "# MOD-45 Case Management with TheHive\n\n**Phase:** 10 Incident Response & DFIR | **Domain:** Incident Response | **Skill level:** Advanced | **Environment:** SOC Stack\n\n**Topics:** Cases; Tasks; Observables; Templates; Analyzers; Alert intake\n\n**Tools:** TheHive; Cortex\n\n## LAB-114 Deploy TheHive and Cortex\n\n**Type:** Lab | **Estimated time:** 5 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-115 Case templates, observables and analyzers\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-116 Send Wazuh alerts to TheHive\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n",
   "parent": "Module_Guides"
  },
  {
   "title": "MOD-46",
   "text": "# MOD-46 Incident Scenarios\n\n**Phase:** 10 Incident Response & DFIR | **Domain:** Incident Response | **Skill level:** Advanced | **Environment:** SOC Stack\n\n**Topics:** Malware; Ransomware; Phishing; Credential compromise; Brute force; Insider threat; Data exfiltration; Web attacks; DDoS; Account takeover; Privilege escalation; Lateral movement\n\n**Tools:** TheHive; Wazuh; Zeek; Suricata; Sysmon\n\n## INV-023 Incident: malware on an endpoint\n\n**Type:** Investigation | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## INV-024 Incident: ransomware\n\n**Type:** Investigation | **Estimated time:** 5 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## INV-025 Incident: brute force and credential compromise\n\n**Type:** Investigation | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## INV-026 Incident: account takeover\n\n**Type:** Investigation | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## INV-027 Incident: insider threat and data exfiltration\n\n**Type:** Investigation | **Estimated time:** 5 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## INV-028 Incident: web attack\n\n**Type:** Investigation | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## INV-029 Incident: DDoS\n\n**Type:** Investigation | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## INV-030 Incident: privilege escalation and lateral movement\n\n**Type:** Investigation | **Estimated time:** 5 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n",
   "parent": "Module_Guides"
  },
  {
   "title": "MOD-47",
   "text": "# MOD-47 Email Security\n\n**Phase:** 10 Incident Response & DFIR | **Domain:** Incident Response | **Skill level:** Core | **Environment:** Lab Network\n\n**Topics:** SMTP; SPF; DKIM; DMARC; ARC; Email headers; Phishing; Business Email Compromise; Malicious attachments; Malicious links\n\n**Tools:** None\n\n## THY-031 SMTP, SPF, DKIM, DMARC and ARC\n\n**Type:** Theory | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-117 Validate SPF, DKIM and DMARC for the lab domain\n\n**Type:** Lab | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## INV-031 Phishing investigation: headers, links and attachments\n\n**Type:** Investigation | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## INV-032 Business Email Compromise investigation\n\n**Type:** Investigation | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n",
   "parent": "Module_Guides"
  },
  {
   "title": "MOD-48",
   "text": "# MOD-48 Digital Forensics\n\n**Phase:** 10 Incident Response & DFIR | **Domain:** Digital Forensics | **Skill level:** Advanced | **Environment:** Analysis Workstation\n\n**Topics:** Evidence preservation; Chain of custody; Disk forensics; File systems; Deleted files; Metadata; Timeline analysis; Memory forensics; Process analysis; Network connections; Malware artifacts\n\n**Tools:** Velociraptor; Volatility; Autopsy; KAPE; Eric Zimmerman tools\n\n## THY-032 Evidence preservation and chain of custody\n\n**Type:** Theory | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-118 Disk image analysis with Autopsy\n\n**Type:** Lab | **Estimated time:** 5 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-119 Windows artifacts with KAPE and Eric Zimmerman tools\n\n**Type:** Lab | **Estimated time:** 5 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-120 Timeline analysis\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-121 Memory analysis with Volatility\n\n**Type:** Lab | **Estimated time:** 5 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-122 Velociraptor deployment, collection and hunts\n\n**Type:** Lab | **Estimated time:** 5 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## INV-033 Host forensic investigation\n\n**Type:** Investigation | **Estimated time:** 6 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## ASM-010 Phase 10 assessment: incident response practical\n\n**Type:** Assessment | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n",
   "parent": "Module_Guides"
  },
  {
   "title": "MOD-49",
   "text": "# MOD-49 Threat Hunting\n\n**Phase:** 11 Threat Hunting & Malware | **Domain:** Threat Hunting | **Skill level:** Advanced | **Environment:** SOC Stack\n\n**Topics:** Hypothesis-driven hunting; IOC hunting; TTP hunting; Behavioral hunting; Baseline analysis; Anomaly detection; Threat intelligence; MITRE mapping\n\n**Tools:** KQL; SPL; EQL; SQL; Sigma; Wazuh; Velociraptor\n\n## THY-033 Hunting method and hypothesis writing\n\n**Type:** Theory | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-123 Baselines and anomaly analysis\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-124 Hunt pack 01: persistence\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-125 Hunt pack 02: credential access\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-126 Hunt pack 03: lateral movement\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-127 Hunt pack 04: command and control\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-128 Hunt pack 05: scripting and built-in tools\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-129 Hunt pack 06: Linux servers\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-130 Hunt pack 07: data exfiltration\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-131 Hunt pack 08: identity anomalies\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-132 Hunt pack 09: indicator-driven hunts\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-133 Hunt pack 10: defense evasion\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n",
   "parent": "Module_Guides"
  },
  {
   "title": "MOD-50",
   "text": "# MOD-50 Malware Analysis\n\n**Phase:** 11 Threat Hunting & Malware | **Domain:** Malware Analysis | **Skill level:** Advanced | **Environment:** Analysis Workstation\n\n**Topics:** Malware lifecycle; PE; ELF; Packers; Obfuscation; Persistence; C2; Static analysis; Dynamic analysis; Behavioral analysis; Instructor-provided training samples only\n\n**Tools:** Ghidra; YARA; capa; VirusTotal; REMnux; FLARE-VM; x64dbg\n\n## THY-034 Malware lifecycle and file formats\n\n**Type:** Theory | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-134 Isolated analysis environment\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-135 Static analysis of a training sample\n\n**Type:** Lab | **Estimated time:** 5 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-136 Write YARA rules\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-137 Behavioural analysis of a training sample\n\n**Type:** Lab | **Estimated time:** 5 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## INV-034 Analysis report with indicators and detections\n\n**Type:** Investigation | **Estimated time:** 5 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## ASM-011 Phase 11 assessment: threat hunting practical\n\n**Type:** Assessment | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n",
   "parent": "Module_Guides"
  },
  {
   "title": "MOD-51",
   "text": "# MOD-51 AWS Security\n\n**Phase:** 12 Cloud & DevSecOps | **Domain:** Cloud Security | **Skill level:** Enterprise | **Environment:** AWS\n\n**Topics:** IAM; VPC; Security Groups; NACL; CloudTrail; GuardDuty; Security Hub; KMS; S3 security; EC2 security\n\n**Tools:** AWS Security\n\n## THY-035 AWS shared responsibility and security services\n\n**Type:** Theory | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-138 IAM review and least privilege\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-139 VPC, Security Groups and NACLs\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-140 CloudTrail, GuardDuty and Security Hub\n\n**Type:** Lab | **Estimated time:** 5 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-141 KMS, S3 and EC2 security\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## INV-035 CloudTrail investigation\n\n**Type:** Investigation | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n",
   "parent": "Module_Guides"
  },
  {
   "title": "MOD-52",
   "text": "# MOD-52 Azure Security\n\n**Phase:** 12 Cloud & DevSecOps | **Domain:** Cloud Security | **Skill level:** Enterprise | **Environment:** Azure\n\n**Topics:** Entra ID; RBAC; NSG; Defender for Cloud; Sentinel; Key Vault; Azure Monitor\n\n**Tools:** Azure Security; Microsoft Entra ID\n\n## LAB-142 Entra ID and Azure RBAC\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-143 NSG, Key Vault and Azure Monitor\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-144 Defender for Cloud\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## INV-036 Entra ID sign-in log investigation\n\n**Type:** Investigation | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n",
   "parent": "Module_Guides"
  },
  {
   "title": "MOD-53",
   "text": "# MOD-53 Container Security\n\n**Phase:** 12 Cloud & DevSecOps | **Domain:** Container & Kubernetes Security | **Skill level:** Advanced | **Environment:** Linux Server\n\n**Topics:** Docker security; Container isolation; Images; Registries; Secrets; Capabilities; Namespaces; cgroups; Container networking; Runtime security\n\n**Tools:** Trivy; Grype; Syft; Docker Scout; Falco; Docker\n\n## THY-036 Container isolation model\n\n**Type:** Theory | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-145 Container host and runtime hardening\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-146 Image scanning and SBOM\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-147 Runtime detection with Falco\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n",
   "parent": "Module_Guides"
  },
  {
   "title": "MOD-54",
   "text": "# MOD-54 Kubernetes Security\n\n**Phase:** 12 Cloud & DevSecOps | **Domain:** Container & Kubernetes Security | **Skill level:** Advanced | **Environment:** Kubernetes Lab Cluster\n\n**Topics:** RBAC; Service Accounts; Network Policies; Secrets; Pod Security; Admission Controllers; API security; etcd; Kubernetes audit logs\n\n**Tools:** Falco; Trivy; Kubescape; kube-bench; Kyverno; OPA Gatekeeper\n\n## LAB-148 Lab cluster, RBAC and service accounts\n\n**Type:** Lab | **Estimated time:** 5 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-149 Network Policies and Pod Security\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-150 Benchmark with kube-bench and Kubescape\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-151 Admission policy with Kyverno\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-152 Kubernetes audit logs and Falco\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n",
   "parent": "Module_Guides"
  },
  {
   "title": "MOD-55",
   "text": "# MOD-55 DevSecOps Pipeline\n\n**Phase:** 12 Cloud & DevSecOps | **Domain:** DevSecOps | **Skill level:** Advanced | **Environment:** Lab Network\n\n**Topics:** Git; CI/CD; SAST; SCA; Secrets Scan; Container Scan; DAST; Deployment; Runtime Security\n\n**Tools:** GitLab; Semgrep; Gitleaks; Trivy; OWASP ZAP; Syft; Grype\n\n## THY-037 Security stages in a delivery pipeline\n\n**Type:** Theory | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-153 SAST and secrets scanning\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-154 Dependency and container scanning\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-155 DAST against the training application\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## PROJECT-007 Secure delivery pipeline from commit to runtime\n\n**Type:** Project | **Estimated time:** 10 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## ASM-012 Phase 12 assessment: cloud security assessment\n\n**Type:** Assessment | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n",
   "parent": "Module_Guides"
  },
  {
   "title": "MOD-56",
   "text": "# MOD-56 Security Programming\n\n**Phase:** 13 Security Automation | **Domain:** Security Programming | **Skill level:** Core | **Environment:** Workstation\n\n**Topics:** Python: Requests, JSON, REST APIs, Regex, Pandas, Scapy, Paramiko, psutil, subprocess, sockets, asyncio; PowerShell: Event logs, Active Directory, Automation; SQL: PostgreSQL, SQLite, SQL Server concepts\n\n**Tools:** Python; PowerShell; SQL; PostgreSQL; SQLite\n\n## LAB-156 Python fundamentals: files, JSON and regex\n\n**Type:** Lab | **Estimated time:** 5 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-157 REST APIs and an enrichment tool\n\n**Type:** Lab | **Estimated time:** 5 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-158 Log analysis with Pandas\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-159 Sockets and packet parsing with Scapy\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-160 Host automation with Paramiko, psutil, subprocess and asyncio\n\n**Type:** Lab | **Estimated time:** 5 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-161 SQL for security data\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-162 PowerShell for Active Directory reporting\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## PROJECT-008 Security toolkit command-line project\n\n**Type:** Project | **Estimated time:** 8 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n",
   "parent": "Module_Guides"
  },
  {
   "title": "MOD-57",
   "text": "# MOD-57 Security Automation and SOAR\n\n**Phase:** 13 Security Automation | **Domain:** Security Automation | **Skill level:** Advanced | **Environment:** SOC Stack\n\n**Topics:** Playbooks; Automated enrichment; Automated response; IOC blocking; User disabling; Email quarantine; Notifications; Ticket creation; API integration; Tines concepts; Sentinel automation\n\n**Tools:** n8n; Shuffle; TheHive; Cortex; Python\n\n## THY-038 SOAR concepts and playbook design\n\n**Type:** Theory | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-163 Deploy n8n and build a first workflow\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-164 Workflow pack 1: alert enrichment and ticket creation\n\n**Type:** Lab | **Estimated time:** 5 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-165 Workflow pack 2: phishing triage and email quarantine\n\n**Type:** Lab | **Estimated time:** 5 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-166 Workflow pack 3: indicator blocking and intelligence sync\n\n**Type:** Lab | **Estimated time:** 5 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-167 Workflow pack 4: user disabling with approval and notification\n\n**Type:** Lab | **Estimated time:** 5 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-168 Workflow pack 5: vulnerability tickets and daily SOC report\n\n**Type:** Lab | **Estimated time:** 5 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## ASM-013 Phase 13 assessment: automation practical\n\n**Type:** Assessment | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n",
   "parent": "Module_Guides"
  },
  {
   "title": "MOD-58",
   "text": "# MOD-58 Enterprise SIEM and XDR Platforms\n\n**Phase:** 14 Advanced Security Engineering | **Domain:** SIEM & Logging | **Skill level:** Enterprise | **Environment:** SOC Stack\n\n**Topics:** Common SIEM concepts across platforms; KQL; SPL; EQL; Analytics rules; Connectors; Automation\n\n**Tools:** Microsoft Sentinel; Microsoft Defender; Microsoft Entra ID; Splunk; Elastic Security\n\n## THY-039 Common concepts across enterprise platforms\n\n**Type:** Theory | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-169 Elastic Security: agents, rules and EQL\n\n**Type:** Lab | **Estimated time:** 6 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-170 Microsoft Sentinel: connectors, KQL analytics and automation\n\n**Type:** Lab | **Estimated time:** 6 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-171 Splunk: ingestion, SPL searches and alerts\n\n**Type:** Lab | **Estimated time:** 5 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-172 Microsoft Defender and Entra ID sign-in protection\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## ASG-019 Port five detections to three platforms and compare\n\n**Type:** Assignment | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n",
   "parent": "Module_Guides"
  },
  {
   "title": "MOD-59",
   "text": "# MOD-59 Security Metrics\n\n**Phase:** 14 Advanced Security Engineering | **Domain:** SOC Operations | **Skill level:** Advanced | **Environment:** SOC Stack\n\n**Topics:** MTTD; MTTR; Alert volume; False-positive rate; Incident volume; Detection coverage; Detection latency; Investigation time; SLA compliance; Vulnerability score; Patch compliance; EDR coverage; MFA coverage\n\n**Tools:** Grafana; Prometheus\n\n## THY-040 Security metrics and how to measure them\n\n**Type:** Theory | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-173 Collect metric data from the SOC tools\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-174 Security metrics dashboards in Grafana\n\n**Type:** Lab | **Estimated time:** 5 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n",
   "parent": "Module_Guides"
  },
  {
   "title": "MOD-60",
   "text": "# MOD-60 SRE and Security\n\n**Phase:** 14 Advanced Security Engineering | **Domain:** SOC Operations | **Skill level:** Advanced | **Environment:** SOC Stack\n\n**Topics:** SRE; SLO; SLA; SLI; Error budgets; Incident management; Observability; Reliability engineering; Security observability\n\n**Tools:** Grafana; Prometheus\n\n## THY-041 SRE principles for security operations\n\n**Type:** Theory | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-175 Service level objectives for the SOC pipeline\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## PROJECT-009 Combined SRE and Security Operations dashboard and incident workflow\n\n**Type:** Project | **Estimated time:** 8 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n",
   "parent": "Module_Guides"
  },
  {
   "title": "MOD-61",
   "text": "# MOD-61 AI for Cybersecurity\n\n**Phase:** 14 Advanced Security Engineering | **Domain:** AI Security | **Skill level:** Advanced | **Environment:** SOC Stack\n\n**Topics:** AI-assisted investigation; Alert summarization; Log analysis; Threat intelligence enrichment; Automated RCA; Detection generation; Threat hunting assistance; RAG; Vector databases; AI agents; Prompt injection; LLM security; AI security\n\n**Tools:** Python\n\n## THY-042 LLM basics, limits and security risks\n\n**Type:** Theory | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-176 Alert summarization and log analysis assistant\n\n**Type:** Lab | **Estimated time:** 5 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-177 Retrieval over runbooks and intelligence\n\n**Type:** Lab | **Estimated time:** 5 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-178 Triage agent with guardrails and human approval\n\n**Type:** Lab | **Estimated time:** 5 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## LAB-179 Test and defend against prompt injection in the lab assistant\n\n**Type:** Lab | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## PROJECT-010 AI-assisted security operations project\n\n**Type:** Project | **Estimated time:** 8 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n",
   "parent": "Module_Guides"
  },
  {
   "title": "MOD-62",
   "text": "# MOD-62 Security Architecture\n\n**Phase:** 14 Advanced Security Engineering | **Domain:** Security Architecture | **Skill level:** Advanced | **Environment:** Workstation\n\n**Topics:** SOC architecture; SIEM architecture; Security data lake; Zero Trust architecture; Identity architecture; Cloud security architecture; Network security architecture; Security monitoring architecture; HA security infrastructure; Disaster recovery\n\n**Tools:** draw.io\n\n## ASG-020 SOC and SIEM architecture design\n\n**Type:** Assignment | **Estimated time:** 5 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## ASG-021 Security data lake design\n\n**Type:** Assignment | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## ASG-022 Zero Trust and identity architecture\n\n**Type:** Assignment | **Estimated time:** 5 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## ASG-023 Cloud and network security architecture\n\n**Type:** Assignment | **Estimated time:** 5 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## ASG-024 High availability and disaster recovery for security infrastructure\n\n**Type:** Assignment | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## ASM-014 Phase 14 assessment: architecture review\n\n**Type:** Assessment | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n",
   "parent": "Module_Guides"
  },
  {
   "title": "MOD-63",
   "text": "# MOD-63 Final Practical SOC Lab\n\n**Phase:** 15 Enterprise SOC Capstone | **Domain:** SOC Operations | **Skill level:** Advanced | **Environment:** SOC Stack\n\n**Topics:** Firewall; IDS/IPS; Linux and Windows endpoints; Sysmon and auditd; Wazuh; Zeek and Suricata; Log pipeline; SIEM; Grafana; Detection engineering; Threat intelligence; TheHive; Velociraptor; n8n automation; Incident response\n\n**Tools:** Wazuh; Zeek; Suricata; Sysmon; auditd; Grafana; TheHive; Velociraptor; n8n; MISP\n\n## LAB-180 Integrate the complete SOC lab\n\n**Type:** Lab | **Estimated time:** 10 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## INV-037 Simulated scenario 1 investigation\n\n**Type:** Investigation | **Estimated time:** 8 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## INV-038 Simulated scenario 2 investigation\n\n**Type:** Investigation | **Estimated time:** 8 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## INV-039 Simulated scenario 3 investigation\n\n**Type:** Investigation | **Estimated time:** 8 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n",
   "parent": "Module_Guides"
  },
  {
   "title": "MOD-64",
   "text": "# MOD-64 Capstone: Enterprise Security Operations Center\n\n**Phase:** 15 Enterprise SOC Capstone | **Domain:** SOC Operations | **Skill level:** Advanced | **Environment:** SOC Stack\n\n**Topics:** Network monitoring; Endpoint monitoring; SIEM; IDS/IPS; Threat intelligence; Detection rules; MITRE ATT&CK mapping; Incident response; Case management; Threat hunting; Vulnerability scanning; Security dashboards; Automation; Security reporting\n\n**Tools:** Wazuh; Zeek; Suricata; Sysmon; MISP; TheHive; Velociraptor; n8n; Grafana; Greenbone/OpenVAS; Sigma; MITRE ATT&CK\n\n## CAP-001 Architecture diagram, network design and security architecture\n\n**Type:** Capstone | **Estimated time:** 8 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## CAP-002 Network and endpoint monitoring\n\n**Type:** Capstone | **Estimated time:** 8 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## CAP-003 SIEM configuration and IDS/IPS\n\n**Type:** Capstone | **Estimated time:** 8 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## CAP-004 Threat intelligence integration\n\n**Type:** Capstone | **Estimated time:** 5 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## CAP-005 Detection rules and MITRE mapping\n\n**Type:** Capstone | **Estimated time:** 8 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## CAP-006 Incident response playbooks and case management\n\n**Type:** Capstone | **Estimated time:** 6 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## CAP-007 Threat hunting and vulnerability scanning\n\n**Type:** Capstone | **Estimated time:** 8 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## CAP-008 Automation workflows\n\n**Type:** Capstone | **Estimated time:** 6 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## CAP-009 Grafana dashboards\n\n**Type:** Capstone | **Estimated time:** 5 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## CAP-010 Security report, executive report and incident investigation report\n\n**Type:** Capstone | **Estimated time:** 8 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## CAP-011 Final presentation\n\n**Type:** Capstone | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## ASM-015 Final assessment\n\n**Type:** Assessment | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n",
   "parent": "Module_Guides"
  },
  {
   "title": "MOD-65",
   "text": "# MOD-65 Career Preparation\n\n**Phase:** 15 Enterprise SOC Capstone | **Domain:** Career | **Skill level:** Core | **Environment:** Workstation\n\n**Topics:** SOC Analyst, SOC Engineer, Cybersecurity Engineer, Security Engineer, Detection Engineer, Threat Hunter, Incident Response, Cloud Security and DevSecOps interviews; Resume; LinkedIn; GitHub portfolio; Security lab portfolio\n\n**Tools:** Git\n\n## ASG-025 GitHub portfolio structure and security lab portfolio\n\n**Type:** Assignment | **Estimated time:** 5 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## ASG-026 Resume and LinkedIn project descriptions\n\n**Type:** Assignment | **Estimated time:** 3 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## ASG-027 Interview question bank: SOC Analyst and SOC Engineer\n\n**Type:** Assignment | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## ASG-028 Interview question bank: Detection, Threat Hunting and Incident Response\n\n**Type:** Assignment | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## ASG-029 Interview question bank: Security Engineer, Cloud Security and DevSecOps\n\n**Type:** Assignment | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n\n## ASM-016 Technical interview labs and scenarios\n\n**Type:** Assessment | **Estimated time:** 4 h\n\n**Steps:** _To be written by the instructor._\n\n**Expected result:** _To be written by the instructor._\n\n**Troubleshooting:** _To be written by the instructor._\n\n**Security relevance:** _To be written by the instructor._\n",
   "parent": "Module_Guides"
  }
 ]
}
