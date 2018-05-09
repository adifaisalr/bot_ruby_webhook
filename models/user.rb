class User < ActiveRecord::Base
  has_many :issues

  def handle
    telegram_username || jira_user_key
  end
end
