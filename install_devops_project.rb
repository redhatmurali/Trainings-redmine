# DevOps Engineering - one-shot Redmine installer
#
# Run on the Redmine server, from the Redmine root directory, as the Redmine OS user:
#
#   STUDENTS=alice,bob INSTRUCTORS=murali \
#     bundle exec rails runner -e production /path/to/install_devops_project.rb
#
# Environment variables (all optional):
#   CSV            path to redmine_issues.csv (default: same directory as this script)
#   STUDENTS       comma-separated Redmine logins; each gets a full personal copy of the curriculum
#   INSTRUCTORS    comma-separated Redmine logins added with the Instructor role
#   TEMPLATE=1     also create one unassigned template copy (status New)
#   SET_DONE_RATIO=1  switch the GLOBAL setting "Calculate the issue done ratio" to "Use the issue status"
#   PROJECT_ID     project identifier (default: devops-engineering)
#
# Safe to re-run: existing objects are kept, students who already have the issues are skipped.
# New students later: run again with STUDENTS=newlogin.

require 'csv'

$stdout.sync = true
def say(msg)
  puts "[devops] #{msg}"
end

def halt(msg)
  puts "[devops] ERROR: #{msg}"
  exit 1
end

script_dir = File.dirname(File.expand_path(__FILE__)) rescue Dir.pwd
csv_path   = ENV['CSV'].to_s.strip
csv_path   = File.join(script_dir, 'redmine_issues.csv') if csv_path.empty?
halt("CSV not found: #{csv_path} (set CSV=/path/to/redmine_issues.csv)") unless File.file?(csv_path)

student_logins    = ENV['STUDENTS'].to_s.split(',').map(&:strip).reject(&:empty?).uniq
instructor_logins = ENV['INSTRUCTORS'].to_s.split(',').map(&:strip).reject(&:empty?).uniq
want_template     = ENV['TEMPLATE'].to_s == '1'
project_ident     = ENV['PROJECT_ID'].to_s.strip
project_ident     = 'devops-engineering' if project_ident.empty?

rows = CSV.read(csv_path, :headers => true, :encoding => 'bom|utf-8').map(&:to_h)
halt('CSV is empty') if rows.empty?
%w(Unique\ ID Curriculum\ ID Tracker Subject Description Category Target\ version Parent Blocked\ by
   Estimated\ hours Technology Difficulty Lab\ Type Environment Evidence\ Required
   Certification\ Relevance Instructor\ Review Priority).each do |col|
  halt("CSV column missing: #{col}") unless rows.first.key?(col)
end
say "CSV: #{rows.size} rows from #{csv_path}"

admin = User.active.where(:admin => true).order(:id).first
halt('no active administrator account found') unless admin
User.current = admin
say "Running as #{admin.login} on Redmine #{Redmine::VERSION}"

# ---------------------------------------------------------------- statuses
STATUS_DEFS = [
  # name, closed, % done
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

if ENV['SET_DONE_RATIO'].to_s == '1'
  Setting.issue_done_ratio = 'issue_status'
  say 'global setting: done ratio now follows the issue status'
end

# ---------------------------------------------------------------- trackers
TRACKER_NAMES = %w(Module Learning Lab Project Assessment)
tr = {}
TRACKER_NAMES.each do |name|
  t = Tracker.where(:name => name).first
  if t.nil?
    t = Tracker.new(:name => name)
    t.default_status = st['New']
    t.core_fields = Tracker::CORE_FIELDS
    t.save!
    say "tracker created: #{name}"
  end
  tr[name] = t
end
work_trackers = %w(Learning Lab Project Assessment).map { |n| tr[n] }

# ---------------------------------------------------------------- enumerations
%w(Learning Lab Configuration Development Troubleshooting Documentation Testing Review).each do |name|
  next if TimeEntryActivity.where(:name => name, :project_id => nil).exists?
  TimeEntryActivity.create!(:name => name, :active => true)
  say "time activity created: #{name}"
end
default_priority = IssuePriority.default || IssuePriority.active.order(:position).first
if default_priority.nil?
  default_priority = IssuePriority.create!(:name => 'Normal', :is_default => true)
end
prio = {}
%w(Low Normal High Urgent).each do |name|
  prio[name] = IssuePriority.where(:name => name).first || default_priority
end

# ---------------------------------------------------------------- custom fields
def distinct(rows, col)
  rows.map { |r| r[col].to_s.strip }.reject(&:empty?).uniq
end

all_t   = TRACKER_NAMES.map { |n| tr[n] }
CF_DEFS = [
  # name, format, possible values, trackers, searchable
  ['Curriculum ID',           'string', nil,                                        all_t,         true],
  ['Technology',              'list',   distinct(rows, 'Technology'),               all_t,         false],
  ['Difficulty',              'list',   distinct(rows, 'Difficulty').sort,          work_trackers, false],
  ['Lab Type',                'list',   distinct(rows, 'Lab Type'),                 work_trackers, false],
  ['Environment',             'list',   distinct(rows, 'Environment'),              all_t,         false],
  ['Evidence Required',       'list',   distinct(rows, 'Evidence Required'),        work_trackers, false],
  ['Certification Relevance', 'list',   distinct(rows, 'Certification Relevance'),  all_t,         false],
  ['Instructor Review',       'list',   ['Pending', 'Approved', 'Changes Requested'], work_trackers, false],
  ['Assessment Score',        'int',    nil,                                        [tr['Assessment'], tr['Project']], false]
]
cf = {}
CF_DEFS.each do |name, format, values, trackers, searchable|
  f = IssueCustomField.where(:name => name).first
  if f.nil?
    f = IssueCustomField.new(:name => name)
    f.field_format = format
    f.possible_values = values if values
    f.is_filter   = true
    f.searchable  = searchable
    f.is_for_all  = false
    f.is_required = false
    f.editable    = true
    f.visible     = true
    f.trackers    = trackers
    f.save!
    say "custom field created: #{name}"
  else
    if values && f.field_format == 'list'
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
  # name, permissions, issue visibility, time entry visibility, assignable
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
  else
    say "role exists, left unchanged: #{name}"
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
full_matrix = all_status_names.product(all_status_names).reject { |a, b| a == b }
module_names  = ['New', 'Assigned', 'In Progress', 'Completed']
module_matrix = module_names.product(module_names).reject { |a, b| a == b }

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
set_transitions(tr['Module'], role['Student'],    [['Assigned', 'In Progress']], st)
set_transitions(tr['Module'], role['Instructor'], module_matrix, st)
set_transitions(tr['Module'], role['Reviewer'],   module_matrix, st)

# Students: curriculum fields are read-only in every status
readonly_core = %w(tracker_id subject description priority_id category_id fixed_version_id
                   assigned_to_id parent_issue_id estimated_hours start_date due_date)
readonly_cf   = CF_DEFS.map { |d| cf[d[0]].id.to_s }
all_t.each do |t|
  WorkflowPermission.where(:tracker_id => t.id, :role_id => role['Student'].id).delete_all
  tracker_cf_ids = t.custom_fields.map { |f| f.id.to_s }
  fields = readonly_core + (readonly_cf & tracker_cf_ids)
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
project = Project.where(:identifier => project_ident).first
if project.nil?
  project = Project.new(:name => 'DevOps Engineering')
  project.identifier  = project_ident
  project.is_public   = false
  project.description = 'Hands-on DevOps Engineering programme: Linux, Git, GitLab, GitLab CI/CD, Docker, ' \
                        'Kubernetes, Helm, Terraform, AWS, Ansible, Argo CD, Prometheus + Grafana, Loki, ' \
                        'OpenBao / Vault, Bash + Python and a final end-to-end project. ' \
                        'One shared project; every student has a personal copy of each issue.'
  project.enabled_module_names = %w(issue_tracking time_tracking wiki files documents calendar gantt)
  project.save!
  project.trackers = all_t
  say "project created: #{project.name} (#{project.identifier})"
else
  say "project exists: #{project.name} (#{project.identifier})"
  missing_mods = %w(issue_tracking time_tracking) - project.enabled_module_names
  project.enabled_module_names = project.enabled_module_names + missing_mods unless missing_mods.empty?
end
project.trackers = (project.trackers.to_a | all_t)
project.issue_custom_fields = (project.issue_custom_fields.to_a | cf.values)
project.save!
project.reload

ver = {}
rows.map { |r| r['Target version'].to_s.strip }.reject(&:empty?).uniq.sort.each do |name|
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

# ---------------------------------------------------------------- issues
textile = Setting.text_formatting.to_s == 'textile'
say 'note: this Redmine uses Textile; descriptions are converted' if textile

def to_textile(text)
  text.to_s.lines.map do |line|
    l = line.chomp
    l = l.sub(/\A### (.*)\z/) { "h3. #{$1}\n" }
    l = l.sub(/\A- \[ \] /, '* ')
    l = l.sub(/\A- /, '* ')
    l = l.gsub(/\*\*(.+?)\*\*/) { "*#{$1}*" }
    l
  end.join("\n")
end

cid_field  = cf['Curriculum ID']
cf_columns = ['Curriculum ID', 'Technology', 'Difficulty', 'Lab Type', 'Environment',
              'Evidence Required', 'Certification Relevance', 'Instructor Review']

def split_refs(value)
  value.to_s.split(',').map(&:strip).reject(&:empty?)
end

# owner: a User, or nil for the unassigned template copy
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
      cf_columns.each do |col|
        v = r[col].to_s.strip
        values[cf[col].id.to_s] = v unless v.empty?
      end
      i.custom_field_values = values
      i.notify = false if i.respond_to?(:notify=)
      unless i.save
        halt("#{label}: #{uid} not saved: #{i.errors.full_messages.join('; ')}")
      end
      by_uid[uid] = i
      fresh[uid]  = i
      new_ids << i.id
      created += 1
      say "#{label}: #{created} issues created" if (created % 50).zero?
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

# No e-mail from this run: the process exits at the end, so the switch is never turned back on here.
ActionMailer::Base.perform_deliveries = false
install_copy.call(nil) if want_template
students.each { |u| install_copy.call(u) }
if students.empty? && !want_template
  say 'no issues created: pass STUDENTS=login1,login2 (or TEMPLATE=1 for an unassigned copy)'
end

# ---------------------------------------------------------------- saved queries
status_ids = lambda { |*names| names.map { |n| st[n].id.to_s } }
cid_col    = "cf_#{cid_field.id}".to_sym
cid_filter = "cf_#{cid_field.id}"
review_col = "cf_#{cf['Instructor Review'].id}".to_sym
score_col  = "cf_#{cf['Assessment Score'].id}".to_sym
diff_col   = "cf_#{cf['Difficulty'].id}".to_sym
me         = { 'assigned_to_id' => { :operator => '=', :values => ['me'] } }
not_module = { 'tracker_id' => { :operator => '!', :values => [tr['Module'].id.to_s] } }
staff      = [role['Instructor'], role['Reviewer']]

QUERY_DEFS = [
  # name, roles (nil = public), filters, columns, group_by, totals, sort
  ['My next tasks', nil,
   me.merge(not_module).merge('status_id' => { :operator => '=', :values => status_ids.call('Assigned', 'In Progress', 'Reopened') }),
   [cid_col, :subject, :status, diff_col, :estimated_hours], 'fixed_version', [:estimated_hours], [['id', 'asc']]],
  ['My blocked', nil,
   me.merge('status_id' => { :operator => '=', :values => status_ids.call('Blocked') }),
   [cid_col, :subject, :updated_on], nil, [], [['updated_on', 'asc']]],
  ['My remaining work', nil,
   me.merge(not_module).merge('status_id' => { :operator => 'o', :values => [''] }),
   [cid_col, :subject, :status, :estimated_hours, :spent_hours], 'fixed_version', [:estimated_hours, :spent_hours], [['id', 'asc']]],
  ['My completed work', nil,
   me.merge(not_module).merge('status_id' => { :operator => '=', :values => status_ids.call('Completed') }),
   [cid_col, :subject, :closed_on, :spent_hours], 'fixed_version', [:spent_hours], [['id', 'asc']]],
  ['My in review', nil,
   me.merge('status_id' => { :operator => '=', :values => status_ids.call('Testing', 'Review') }),
   [cid_col, :subject, :status, review_col, :updated_on], nil, [], [['updated_on', 'asc']]],
  ['My assessments', nil,
   me.merge('status_id' => { :operator => '*', :values => [''] },
            'tracker_id' => { :operator => '=', :values => [tr['Assessment'].id.to_s] }),
   [cid_col, :subject, :status, score_col], nil, [], [['id', 'asc']]],
  ['Instructor: review queue', staff,
   { 'status_id' => { :operator => '=', :values => status_ids.call('Review') } },
   [cid_col, :subject, :assigned_to, :updated_on], nil, [], [['updated_on', 'asc']]],
  ['Instructor: blocked students', staff,
   { 'status_id' => { :operator => '=', :values => status_ids.call('Blocked') } },
   [cid_col, :subject, :updated_on], 'assigned_to', [], [['updated_on', 'asc']]],
  ['Instructor: progress by student', staff,
   not_module.merge('status_id' => { :operator => '*', :values => [''] }),
   [cid_col, :subject, :status, :estimated_hours, :spent_hours], 'assigned_to', [:estimated_hours, :spent_hours], [['id', 'asc']]],
  ['Instructor: progress by module', staff,
   not_module.merge('status_id' => { :operator => '*', :values => [''] }),
   [cid_col, :subject, :assigned_to, :status, :estimated_hours, :spent_hours], 'fixed_version', [:estimated_hours, :spent_hours], [['id', 'asc']]],
  ['Instructor: compare one task', staff,
   { 'status_id' => { :operator => '*', :values => [''] }, cid_filter => { :operator => '=', :values => ['LINUX-001'] } },
   [cid_col, :assigned_to, :status, :spent_hours, review_col], nil, [], [['id', 'asc']]],
  ['Instructor: assessment scores', staff,
   { 'status_id' => { :operator => '*', :values => [''] },
     'tracker_id' => { :operator => '=', :values => [tr['Assessment'].id.to_s] } },
   [cid_col, :subject, :assigned_to, :status, score_col], 'fixed_version', [], [['id', 'asc']]],
  ['Instructor: stale work', staff,
   { 'status_id' => { :operator => '=', :values => status_ids.call('In Progress') },
     'updated_on' => { :operator => '<t-', :values => ['7'] } },
   [cid_col, :subject, :assigned_to, :updated_on], 'assigned_to', [], [['updated_on', 'asc']]]
]

queries_made = 0
QUERY_DEFS.each do |name, roles, filters, columns, group_by, totals, sort|
  begin
    next if IssueQuery.where(:project_id => project.id, :name => name).exists?
    q = IssueQuery.new(:name => name)
    q.project = project
    q.user    = admin
    q.filters = filters
    q.column_names    = columns
    q.group_by        = group_by
    q.totalable_names = totals
    q.sort_criteria   = sort
    if roles
      q.visibility = Query::VISIBILITY_ROLES
      q.roles      = roles
    else
      q.visibility = Query::VISIBILITY_PUBLIC
    end
    q.save!
    queries_made += 1
  rescue => e
    say "warning: saved query '#{name}' skipped (#{e.message})"
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
