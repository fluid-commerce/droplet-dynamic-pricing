class User < ApplicationRecord
  # Include default devise modules. Others available are:
  # :confirmable, :lockable, :timeoutable, :trackable and :omniauthable
  #
  # Not :registerable. Anyone who can sign in gets the full admin UI
  # (AdminPermissions is `can :manage, :all`), so public sign-up would hand out
  # admin. Staff accounts are created by an existing admin, never self-served.
  devise :database_authenticatable,
         :recoverable, :rememberable, :validatable

  def has_permission_set?(set_name)
    permission_sets.include?(set_name)
  end

  def add_permission_set(set_name)
    self.permission_sets = (permission_sets + [ set_name ]).uniq
    save
  end

  def remove_permission_set(set_name)
    self.permission_sets = permission_sets - [ set_name ]
    save
  end
end
