# typed: true
# frozen_string_literal: true

require "utils/curl"

# Auditing functions for rules common to both casks and formulae.
#
# @api private
module SharedAudits
  include Utils::Curl
  extend Utils::Curl

  module_function

  def github_repo_data(user, repo)
    @github_repo_data ||= {}
    @github_repo_data["#{user}/#{repo}"] ||= GitHub.repository(user, repo)

    @github_repo_data["#{user}/#{repo}"]
  rescue GitHub::HTTPNotFoundError
    nil
  end

  def github_release_data(user, repo, tag)
    id = "#{user}/#{repo}/#{tag}"
    @github_release_data ||= {}
    @github_release_data[id] ||= GitHub.open_api("#{GitHub::API_URL}/repos/#{user}/#{repo}/releases/tags/#{tag}")

    @github_release_data[id]
  rescue GitHub::HTTPNotFoundError
    nil
  end

  def github_release(user, repo, tag, formula: nil, cask: nil)
    release = github_release_data(user, repo, tag)
    return unless release

    exception, name, version = if formula
      [tap_audit_exception(:github_prerelease_allowlist, formula.tap, formula.name), formula.name, formula.version]
    elsif cask
      [tap_audit_exception(:github_prerelease_allowlist, cask.tap, cask.token), cask.token, cask.version]
    end

    return "#{tag} is a GitHub pre-release." if release["prerelease"] && [version, "all"].exclude?(exception)

    return "#{tag} is not a GitHub pre-release but '#{name}' is in the GitHub prerelease allowlist." if exception

    return "#{tag} is a GitHub draft." if release["draft"]
  end

  def gitlab_repo_data(user, repo)
    @gitlab_repo_data ||= {}
    @gitlab_repo_data["#{user}/#{repo}"] ||= begin
      out, _, status = curl_output("https://gitlab.com/api/v4/projects/#{user}%2F#{repo}")
      JSON.parse(out) if status.success?
    end
  end

  def gitlab_release_data(user, repo, tag)
    id = "#{user}/#{repo}/#{tag}"
    @gitlab_release_data ||= {}
    @gitlab_release_data[id] ||= begin
      out, _, status = curl_output(
        "https://gitlab.com/api/v4/projects/#{user}%2F#{repo}/releases/#{tag}", "--fail"
      )
      JSON.parse(out) if status.success?
    end
  end

  def gitlab_release(user, repo, tag, formula: nil, cask: nil)
    release = gitlab_release_data(user, repo, tag)
    return unless release

    return if Date.parse(release["released_at"]) <= Date.today

    exception, version = if formula
      [tap_audit_exception(:gitlab_prerelease_allowlist, formula.tap, formula.name), formula.version]
    elsif cask
      [tap_audit_exception(:gitlab_prerelease_allowlist, cask.tap, cask.token), cask.version]
    end
    return if [version, "all"].include?(exception)

    "#{tag} is a GitLab pre-release."
  end

  def github(user, repo)
    metadata = github_repo_data(user, repo)

    return if metadata.nil?

    return "GitHub fork (not canonical repository)" if metadata["fork"]

    if (metadata["forks_count"] < 30) && (metadata["subscribers_count"] < 30) &&
       (metadata["stargazers_count"] < 75)
      return "GitHub repository not notable enough (<30 forks, <30 watchers and <75 stars)"
    end

    return if Date.parse(metadata["created_at"]) <= (Date.today - 30)

    "GitHub repository too new (<30 days old)"
  end

  def gitlab(user, repo)
    metadata = gitlab_repo_data(user, repo)

    return if metadata.nil?

    return "GitLab fork (not canonical repository)" if metadata["fork"]
    if (metadata["forks_count"] < 30) && (metadata["star_count"] < 75)
      return "GitLab repository not notable enough (<30 forks and <75 stars)"
    end

    return if Date.parse(metadata["created_at"]) <= (Date.today - 30)

    "GitLab repository too new (<30 days old)"
  end

  def bitbucket(user, repo)
    api_url = "https://api.bitbucket.org/2.0/repositories/#{user}/#{repo}"
    out, _, status= curl_output("--request", "GET", api_url)
    return unless status.success?

    metadata = JSON.parse(out)
    return if metadata.nil?

    return "Uses deprecated mercurial support in Bitbucket" if metadata["scm"] == "hg"

    return "Bitbucket fork (not canonical repository)" unless metadata["parent"].nil?

    return "Bitbucket repository too new (<30 days old)" if Date.parse(metadata["created_on"]) >= (Date.today - 30)

    forks_out, _, forks_status= curl_output("--request", "GET", "#{api_url}/forks")
    return unless forks_status.success?

    watcher_out, _, watcher_status= curl_output("--request", "GET", "#{api_url}/watchers")
    return unless watcher_status.success?

    forks_metadata = JSON.parse(forks_out)
    return if forks_metadata.nil?

    watcher_metadata = JSON.parse(watcher_out)
    return if watcher_metadata.nil?

    return if forks_metadata["size"] >= 30 || watcher_metadata["size"] >= 75

    "Bitbucket repository not notable enough (<30 forks and <75 watchers)"
  end

  def github_tag_from_url(url)
    url = url.to_s
    tag = url.match(%r{^https://github\.com/[\w-]+/[\w-]+/archive/([^/]+)\.(tar\.gz|zip)$})
             .to_a
             .second
    tag ||= url.match(%r{^https://github\.com/[\w-]+/[\w-]+/releases/download/([^/]+)/})
               .to_a
               .second
    tag
  end

  def gitlab_tag_from_url(url)
    url = url.to_s
    url.match(%r{^https://gitlab\.com/[\w-]+/[\w-]+/-/archive/([^/]+)/})
       .to_a
       .second
  end

  def tap_audit_exception(list, tap, formula_or_cask, value = nil)
    return false if tap.audit_exceptions.blank?
    return false unless tap.audit_exceptions.key? list

    list = tap.audit_exceptions[list]

    case list
    when Array
      list.include? formula_or_cask
    when Hash
      return false if list.exclude? formula_or_cask
      return list[formula_or_cask] if value.blank?

      list[formula_or_cask] == value
    end
  end
end
