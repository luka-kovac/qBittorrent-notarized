# frozen_string_literal: true

require "fileutils"
require "json"
require "yaml"

# Adapt the workflow at the selected release tag, rather than maintain a second
# copy of its dependency installation, build, tests, or packaging commands.
module UpstreamBuild
  SECRET_NAMES = %w[
    build_certificate_base64 p12_password keychain_password apple_id
    app_specific_password team_id developer_name
  ].freeze
  STEP_KEYS = %w[
    name id if uses with env run shell working-directory continue-on-error
  ].freeze

  def self.rewrite(value)
    case value
    when Hash
      value.to_h { |key, item| [key, rewrite(item)] }
    when Array
      value.map { |item| rewrite(item) }
    when String
      value.gsub(/\$\{\{.*?\}\}/m) do |expression|
        # Composite actions receive the caller's matrix through an input.
        expression.gsub(/\bmatrix\./, "fromJSON(inputs.matrix).")
      end
    else
      value
    end
  end

  def self.prepare(workflow)
    job = workflow.fetch("jobs").fetch("ci")
    unsupported_job = job.keys - %w[
      name runs-on permissions strategy env steps defaults timeout-minutes
    ]
    raise "Unsupported upstream job fields: #{unsupported_job.join(', ')}" unless unsupported_job.empty?

    strategy = job.fetch("strategy")
    unsupported_strategy = strategy.keys - %w[matrix fail-fast max-parallel]
    raise "Unsupported upstream strategy: #{unsupported_strategy.join(', ')}" unless unsupported_strategy.empty?

    matrix = strategy.fetch("matrix")
    %w[libtorrent qbt_gui qt_version].each { |axis| matrix.fetch(axis) }
    runner = job.fetch("runs-on")
    if JSON.generate(runner).include?("${{")
      raise "An upstream runner expression needs explicit support"
    end

    defaults = (workflow.dig("defaults", "run") || {}).merge(job.dig("defaults", "run") || {})
    unknown_defaults = defaults.keys - %w[shell working-directory]
    raise "Unsupported upstream run defaults: #{unknown_defaults.join(', ')}" unless unknown_defaults.empty?

    steps = Marshal.load(Marshal.dump(job.fetch("steps")))
    checkouts = steps.select { |step| step.fetch("uses", "").start_with?("actions/checkout@") }
    raise "Expected one upstream source checkout" unless checkouts.length == 1 && steps.first == checkouts.first
    checkout = checkouts.first
    # The wrapper checks out the selected upstream tag before downloading the
    # generated action, so checkout cannot erase the action while it is running.
    unless (checkout.keys - %w[name uses with]).empty? &&
           (checkout.fetch("with", {}).keys - %w[persist-credentials]).empty?
      raise "Upstream checkout settings changed; update the source checkout adapter"
    end
    steps.shift

    packaging_steps = steps.select { |step| step.fetch("run", "").include?("# code signing") }
    raise "Expected one upstream code-signing block" unless packaging_steps.length == 1
    packaging = packaging_steps.first
    signing_block = /^([ \t]*)# code signing\n.*?^\1# create \.dmg\n/m
    unless packaging.fetch("run").scan(signing_block).length == 1 &&
           packaging.fetch("run").include?("codesign --force --sign -")
      raise "Upstream packaging layout changed; cannot safely insert notarization"
    end
    packaging["run"] = packaging.fetch("run").sub(signing_block) do
      indent = Regexp.last_match(1)
      "#{indent}# Developer ID signing and notarization, before upstream creates the DMG.\n" \
        "#{indent}bash \"${GITHUB_ACTION_PATH}/notarize.sh\" \"${appName}.app\"\n" \
        "#{indent}# create .dmg\n"
    end
    packaging["env"] ||= {}
    SECRET_NAMES.each do |name|
      packaging["env"][name.upcase] = "${{ inputs.#{name} }}"
    end

    # Export workflow/job env once, preserving subsequent GITHUB_ENV updates by
    # upstream actions (notably the OpenSSL and Qt CMAKE_PREFIX_PATH settings).
    upstream_env = workflow.fetch("env", {}).merge(job.fetch("env", {}))
    unless upstream_env.empty?
      export = <<~'PYTHON'
        python3 - <<'PY'
        import json, os, uuid
        names = json.loads(NAMES_JSON)
        with open(os.environ["GITHUB_ENV"], "a") as output:
            for name in names:
                delimiter = "upstream_" + uuid.uuid4().hex
                output.write(f"{name}<<{delimiter}\n{os.environ[name]}\n{delimiter}\n")
        PY
      PYTHON
      export = export.sub("NAMES_JSON", JSON.generate(JSON.generate(upstream_env.keys)))
      steps.unshift("name" => "Load upstream build environment", "shell" => "bash", "env" => upstream_env, "run" => export)
    end

    steps.each do |step|
      unsupported = step.keys - STEP_KEYS
      raise "Unsupported upstream step fields: #{unsupported.join(', ')}" unless unsupported.empty?
      if step.key?("run")
        # GitHub's implicit macOS shell is bash -e; explicit bash would also add
        # pipefail, changing the upstream commands' behavior.
        step["shell"] ||= defaults.fetch("shell", "bash -e {0}")
        step["working-directory"] ||= defaults["working-directory"] if defaults.key?("working-directory")
      end
      if step["if"].is_a?(String) && !step["if"].include?("${{")
        step["if"] = "${{ #{step.fetch('if')} }}"
      end
    end
    steps = rewrite(steps)
    serialized = JSON.generate(steps)
    if serialized.match?(/\$\{\{[^}]*\b(?:needs|secrets|strategy)\./)
      raise "Upstream uses a job-only context unavailable inside a composite action"
    end

    inputs = { "matrix" => { "description" => "Exact upstream matrix entry", "required" => true } }
    SECRET_NAMES.each do |name|
      inputs[name] = { "description" => "Signing credential: #{name}", "required" => true }
    end
    action = {
      "name" => "Upstream macOS build with notarization",
      "description" => "Build commands from the selected qBittorrent release tag",
      "inputs" => inputs,
      "runs" => { "using" => "composite", "steps" => steps }
    }
    outputs = {
      "matrix" => matrix,
      "runner" => runner,
      "fail_fast" => strategy.fetch("fail-fast", true),
      "max_parallel" => strategy.fetch("max-parallel", 256),
      "timeout" => job.fetch("timeout-minutes", 360)
    }
    [action, outputs]
  end
end

if $PROGRAM_NAME == __FILE__
  workflow_path, action_dir = ARGV
  abort "Usage: prepare_upstream.rb WORKFLOW ACTION_DIR" unless workflow_path && action_dir
  begin
    workflow = YAML.safe_load(File.read(workflow_path), aliases: false)
    action, outputs = UpstreamBuild.prepare(workflow)
    FileUtils.mkdir_p(action_dir)
    File.write(File.join(action_dir, "action.yml"), YAML.dump(action))
    File.open(ENV.fetch("GITHUB_OUTPUT"), "a") do |output|
      outputs.each { |key, value| output.puts("#{key}=#{JSON.generate(value)}") }
    end
    puts "Using the upstream macOS workflow from #{ENV.fetch('UPSTREAM_TAG', workflow_path)}"
    puts "Upstream matrix: #{JSON.generate(outputs.fetch('matrix'))}"
  rescue KeyError, RuntimeError => error
    abort "Cannot adapt upstream macOS workflow: #{error.message}"
  end
end
