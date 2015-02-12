class CapMailer < ActionMailer::Base

  @@default_base_config ||= ActiveSupport::InheritableOptions.new({
    :sender_address           => %("#{(defined?(Rails) ? Rails.env.capitalize : defined?(RAILS_ENV) ? RAILS_ENV.capitalize : defined?(ENV) ? ENV['RAILS_ENV'] : "")} Capistrano Deployment" <capistrano.mailer@example.com>),
    :recipient_addresses      => [],
    # Customize the subject line
    :subject_prepend          => "[DEPLOYMENT]-[#{(defined?(Rails) ? Rails.env.capitalize : defined?(RAILS_ENV) ? RAILS_ENV.capitalize : defined?(ENV) ? ENV['RAILS_ENV'] : "")}] ",
    :subject_append           => nil,
    # Include which sections of the deployment email?
    :sections                 => %w(deployment release_data source_control latest_release previous_release other_deployment_info extra_information commits),
    :site_name                => "",
    :template_prefixes        => { :success => nil, :failure => "failed" },
    :template_path            => "#{File.dirname(__FILE__)}/../views",
    :attach_log_on            => :failure
  })

  cattr_accessor :default_base_config
  attr_accessor  :config, :options
  attr_accessor  :date, :time, :inferred_command, :task_name, :repo_end

  def self.configure(&block)
    yield @@default_base_config
  end

  def self.configure_capistrano_mailer(&block)
    puts "Deprecated 'configure_capistrano_mailer'.  Please update your capistrano_mailer configuration to use 'configure' instead of 'configure_capistrano_mailer'"
  end

  self.prepend_view_path default_base_config[:template_path]
  self.register_interceptor InlineStyle::Mail::Interceptor.new(:stylesheets_path =>
    (default_base_config[:stylesheets_path] || "#{File.dirname(__FILE__)}/../assets")
  )

  def self.reloadable?() false end

  def notification_email(cap, config = {}, *args)
    @options = { :release_data => {}, :extra_information => {}, :data => {} }.merge(args.extract_options!)
    @config  = default_base_config.merge(config.reverse_merge({
          :rails_env          => cap.rails_env,
          :host               => (cap.host rescue ''),
          :task_name          => cap.task_name,
          :application        => cap.application,
          :repository         => cap.repository,
          :scm                => cap.scm,
          :deploy_via         => cap.deploy_via,
          :deploy_to          => cap.deploy_to,
          :revision           => cap.revision,
          :real_revision      => cap.real_revision,
          :release_name       => cap.release_name,
          :release_notes      => (cap.release_notes rescue ''),
          :version_dir        => cap.version_dir,
          :shared_dir         => cap.shared_dir,
          :current_dir        => cap.current_dir,
          :releases_path      => cap.releases_path,
          :shared_path        => cap.shared_path,
          :current_path       => cap.current_path,
          :release_path       => cap.release_path,
          :releases           => cap.releases,
          :current_release    => cap.current_release,
          :previous_release   => cap.previous_release,
          :current_revision   => cap.current_revision,
          :latest_revision    => cap.latest_revision,
          :previous_revision  => cap.previous_revision,
          :run_method         => cap.run_method,
          :latest_release     => cap.latest_release
    }))

    @date             = Date.today.to_s
    @time             = Time.now.strftime("%I:%M %p").to_s
    @inferred_command = "cap #{@config[:rails_env]} #{@config[:task_name]}"
    @task_name        = @config[:task_name] || "unknown"

    repo  = @config[:repository]
    x     = repo.include?('/') ? repo.rindex('/') - 1 : repo.length
    front = repo.slice(0..x)
    back  = repo.sub(front, '')
    unless back == 'trunk'
      x = front.include?('/') ? front.rindex('/') - 1 : front.length
      front = front.slice(0..x)
    end
    @repo_end = repo.sub(front, '')

    body_data_hash.each_pair do |k, v|
      self.instance_variable_set("@#{k}", v)
    end

    log = cap.fetch(:full_log)
    fail_pattern = /^failed|rolling back/i
    @job_status = (log =~ fail_pattern) ? :failure : cap.fetch(:mailer_status, :success)
    template_prefix = @config[:template_prefixes][@job_status] ? "#{@config[:template_prefixes][@job_status]}." : ""
    template_name = @config[:template_name] || "#{template_prefix}#{action_name}"

    attach_log = case @config[:attach_log_on]
      when Symbol, String
        @job_status == @config[:attach_log_on].to_sym
      when Array
        @config[:attach_log_on].collect(&:to_sym).include? @job_status
      else
        false
    end

    if attach_log
      log_file_name = "deploy-log-#{Time.now.strftime("%Y-%m-%d-%H%M%S")}.txt"
      attachments[log_file_name] = { :content => log, :mime_type => "text/plain" }
    end

    self.config.assets_dir = "#{File.dirname(__FILE__)}/../assets"

    mail :subject       => "#{@job_status.to_s.upcase}: #{subject_line}",
         :to            => @config[:recipient_addresses],
         :from          => @config[:sender_address],
         :template_name => template_name
  end

  private

    def git_log
      return unless git_range
      `git log #{git_range} --no-merges --format=format:"%h %s (%an)"`
    end


    def git_range
      "#{config[:previous_revision]}..#{config[:latest_revision]}"
    end

    def subject_line
      #The subject prepend and append are useful for people to setup filters in mail clients.
      user = config[:user] ? " by #{config[:user]}" : ""
      middle = config[:subject] ? config[:subject] : "[#{config[:rails_env].upcase}][#{repo_end}] #{inferred_command}#{user}"
      "#{config[:subject_prepend]}#{middle}#{config[:subject_append]}"
    end

    def body_data_hash
      options[:data].merge({
        :section_data     => section_data_hash,
        :date             => date,
        :time             => time,
        :task_name        => task_name,
        :inferred_command => inferred_command,
        :repo_end         => repo_end,
        :site_name        => config[:site_name],
        :site_url         => config[:site_url],
        :application      => config[:application],
        :sections         => config[:sections]
      })
    end

    def section_data_hash
      {
        :deployment             => section_hash_deployment,
        :source_control         => section_hash_source_control,
        :latest_release         => section_hash_latest_release,
        :previous_release       => section_hash_previous_release,
        :other_deployment_info  => section_hash_other_deployment_info,
        :release_data           => options[:release_data],
        :extra_information      => options[:extra_information],
        :commits                => section_hash_commits
      }
    end

    def section_hash_deployment
      {
        :date             => date,
        :time             => time,
        :rails_env        => config[:rails_env],
        :task_name        => task_name,
        :inferred_command => inferred_command,
        :host             => config[:host],
        :release_name     => config[:release_name],
        :release_notes    => config[:release_notes]
      }
    end

    def section_hash_source_control
      {
        :revision         => config[:revision],
        :released         => repo_end,
        :repository       => config[:repository],
        :branch           => config[:branch],
        :scm              => config[:scm],
        :deploy_via       => config[:deploy_via],
        :deploy_to        => config[:deploy_to]
      }
    end

    def section_hash_latest_release
      {
        :latest_release   => config[:latest_release],
        :latest_revision  => config[:latest_revision],
        :release_path     => config[:release_path],
        :real_revision    => config[:real_revision],
        :current_path     => config[:current_path]
      }
    end

    def section_hash_previous_release
      {
        :current_release    => config[:current_release],
        :current_revision   => config[:current_revision],
        :previous_release   => config[:previous_release],
        :previous_revision  => config[:previous_revision],
        :releases           => config[:releases]
      }
    end

    def section_hash_other_deployment_info
      {
        :version_dir    => config[:version_dir],
        :shared_dir     => config[:shared_dir],
        :current_dir    => config[:current_dir],
        :releases_path  => config[:releases_path],
        :shared_path    => config[:shared_path],
        :run_method     => config[:run_method],
        :ip_address     => config[:ip_address]
      }
    end

    def section_hash_commits
      {
        :git_log => git_log
      }
    end
end
