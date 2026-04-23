# frozen_string_literal: true

#-- copyright
# OpenProject is an open source project management software.
# Copyright (C) the OpenProject GmbH
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License version 3.
#
# OpenProject is a fork of ChiliProject, which is a fork of Redmine. The copyright follows:
# Copyright (C) 2006-2013 Jean-Philippe Lang
# Copyright (C) 2010-2013 the ChiliProject Team
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
#
# See COPYRIGHT and LICENSE files for more details.
#++

require Rails.root.join("db/migrate/migration_utils/permission_adder")

# Editing start_date and due_date used to be gated by :edit_work_packages.
# After introducing the dedicated :edit_work_package_dates permission, roles
# that previously allowed date editing would lose that ability on upgrade.
# Preserve the status quo by granting the new permission to every role that
# currently has :edit_work_packages. Admins can selectively revoke it via
# Administration → Roles and permissions.
class AddEditWorkPackageDatesPermissionToRoles < ActiveRecord::Migration[8.1]
  def up
    ::Migration::MigrationUtils::PermissionAdder.add(:edit_work_packages, :edit_work_package_dates)
  end

  def down
    RolePermission.where(permission: "edit_work_package_dates").delete_all
  end
end
