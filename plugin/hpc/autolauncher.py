from __future__ import absolute_import
from __future__ import division
from __future__ import print_function
from __future__ import unicode_literals
import argparse
import json
import logging
import os
import pprint
import subprocess
import sys
from abc import abstractmethod
from time import strftime

CLUSTER_BASE_PATH = '/gpfs/projects/bsc70'
MC_PATH = CLUSTER_BASE_PATH + '/bin/mc'
root = logging.getLogger()
root.setLevel(logging.INFO)
handler = logging.StreamHandler(sys.stdout)
handler.setLevel(logging.INFO)
formatter = logging.Formatter('%(asctime)s - %(name)s - %(levelname)s - %(message)s')
handler.setFormatter(formatter)
root.addHandler(handler)

class LauncherWriter(object):
    def __init__(self, configuration):
        self.configuration = configuration
    def launcher_code(self):
        return '\n'.join(self.launcher_headers()) + '\n\n' + '\n'.join(self.launcher_command()) + '\n'
    @abstractmethod
    def launcher_headers(self): pass
    @abstractmethod
    def launcher_command(self): pass
    def ctag(self):
        return self.configuration['continue_commit_tag'] if self.configuration.get('continue_commit_tag', '') != '' else '$CI_COMMIT_SHORT_SHA'
    def python_command(self):
        args = self.configuration.get('args', '')
        command = self.configuration['workdir'] + "/" + self.configuration['command'] if self.configuration['use_code_in_gpfs'] else self.configuration['command']
        commit_tag = "commit_tag=" + self.ctag() if self.configuration['add_commit_tag'] else ""
        return self.configuration['binary'] + " " + command + " " + args + " " + commit_tag

class SlurmLauncherWriter(LauncherWriter):
    @abstractmethod
    def extra_headers(self): pass
    def launcher_headers(self):
        headers = [
            '#!/bin/bash',
            '#SBATCH --job-name={job_name}'.format(**self.configuration),
            '#SBATCH --chdir={workdir}'.format(**self.configuration),
            '#SBATCH --output={output_filename}_%j_out.txt'.format(**self.configuration),
            '#SBATCH --error={error_filename}_%j_err.txt'.format(**self.configuration),
            '#SBATCH --ntasks={ntasks}'.format(**self.configuration),
            '#SBATCH --qos={qos}'.format(**self.configuration),
            '#SBATCH --time={time}'.format(**self.configuration),
        ]
        for k in ['nodes', 'cpus-per-task', 'tasks-per-node']:
            if self.configuration.get(k): headers.append(f'#SBATCH --{k}={self.configuration[k]}')
        if self.configuration.get('ntasks-per-SlurmLauncherWriter'):
            headers.append('#SBATCH --ntasks-per-socket={ntasks-per-socket}'.format(**self.configuration))
        if self.configuration.get('exclusive'): headers.append('#SBATCH --exclusive')
        return headers + self.extra_headers()

class MNLauncherWriter(SlurmLauncherWriter):
    def extra_headers(self):
        return ['#SBATCH --constraint=highmem'] if self.configuration.get('highmem') else []
    def launcher_command(self):
        return []
    def get_extra_singularity_flags(self): return ''

class P9LauncherWriter(SlurmLauncherWriter):
    def extra_headers(self): return []
    def launcher_command(self): return []

class AMDLauncher(MNLauncherWriter):
    def extra_headers(self):
        gres = int(self.configuration.get('gres') or 1)
        return ['#SBATCH --gres=gpu:' + str(gres)]
    def get_extra_singularity_flags(self):
        return '--rocm'
    def launcher_command(self):
        command = ['module load rocm singularity', 'export PYTHONPATH=src', 'unset TMPDIR']
        SINGULARITY_PATH = 'singularity'
        SINGULARITY_BINDINGS = ['/gpfs/projects/bsc70/hpai/storage/data/:/gpfs/projects/bsc70/hpai/storage/data/']
        if 'bindings_list' in self.configuration:
            SINGULARITY_BINDINGS += self.configuration['bindings_list']
        SINGULARITY_BINDINGS_CMD = ' '.join("-B {}".format(bind) for bind in SINGULARITY_BINDINGS)
        
        # FIX: Ensure image is passed, ensure NO WRITABLE flag
        SINGULARITY_IMAGE = self.configuration['containerdir']
        extra_flags = self.get_extra_singularity_flags()

        SINGULARITY_COMMAND = (
            SINGULARITY_PATH + " exec " + extra_flags + " \\\n" +
            " " + SINGULARITY_BINDINGS_CMD + " \\\n" +
            " " + SINGULARITY_IMAGE + " \\\n" +
            " bash -c \"" + self.python_command() + "\""
        )

        command.append(SINGULARITY_COMMAND)
        root.info('**LAUNCHING COMMAND** %s', str(command))
        return command

class MiniNLauncherWriter(LauncherWriter):
    def extra_headers(self): return []
    def launcher_headers(self): return ['#!/bin/bash']
    def launcher_command(self): return []

LAUNCHER_WRITERS = {'mn4': MNLauncherWriter, 'p9': P9LauncherWriter, 'local': MiniNLauncherWriter, 'amd': AMDLauncher}

def get_job_launcher_name(params):
    num = 0
    current_commit = os.getenv('CI_COMMIT_SHORT_SHA', 'unknown')
    project = os.getenv('CI_PROJECT_PATH_SLUG', 'unknown')
    while True:
        job_name = (project + '_' + current_commit + '_{:03d}').format(num).replace('/', '_')
        filename = 'launcher_' + job_name + '.cmd'
        filepath = os.path.join(params['launchers_dir'], filename)
        if not os.path.exists(filepath): break
        num += 1
    return job_name, filepath

def complete_params(params):
    if not params.get('launchers_dir'): params['launchers_dir'] = os.path.join(params['workdir'], 'launchers')
    if not params.get('output_dir'): params['output_dir'] = os.path.join(params['workdir'], 'output')
    job_name, launcher_filepath = get_job_launcher_name(params)
    if not params.get('job_name'): params['job_name'] = job_name
    if not params.get('launcher_filepath'): params['launcher_filepath'] = launcher_filepath
    if not params.get('output_filename'): params['output_filename'] = os.path.join(params['output_dir'], strftime('%Y%m%d%H%M%S') + '_' + job_name)
    if not params.get('error_filename'): params['error_filename'] = os.path.join(params['output_dir'], strftime('%Y%m%d%H%M%S') + '_' + job_name)
    return params

def make_dirs(params):
    for key in ['launchers_dir', 'output_dir']:
        if not os.path.exists(params[key]):
            try: os.makedirs(params[key])
            except: pass

def write_launcher(configuration):
    launcher = LAUNCHER_WRITERS[configuration['cluster']](configuration)
    with open(configuration['launcher_filepath'], 'w') as f:
        f.write(launcher.launcher_code())

def launch_job(params):
    try:
        cmd = ('bash ' if params['cluster'] == 'local' else 'sbatch ') + params['launcher_filepath']
        out = subprocess.check_output(cmd, shell=True)
        root.info(out)
        return out
    except Exception as e:
        root.error('Could not launch job')
        raise e

def create_and_launch(params):
    params = complete_params(params)
    make_dirs(params)
    write_launcher(params)
    if not params.get('nolaunch'): launch_job(params)

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('-f', '--file', default='/gpfs/projects/bsc70/hpai/storage/data/{{CLUSTER_WORKING_DIR}}/dataset_preprocessing.json')
    parser.add_argument('--cluster')
    parser.add_argument('--command')
    parser.add_argument('--commit')
    parser.add_argument('-p', '--project')
    parser.add_argument('-w', '--workdir')
    parser.add_argument('-c', '--containerdir')
    parser.add_argument('-l', '--singularity-version')
    parser.add_argument('-b', '--binary')
    parser.add_argument('-t', '--add-commit-tag')
    parser.add_argument('-n', '--nolaunch')
    parser.add_argument('-g', '--use-code-in-gpfs', action='store_true')
    defaults = {'binary': 'python', 'singularity_version': '3.6.4', 'add_commit_tag': False, 'use_code_in_gpfs': True}
    args = parser.parse_args()
    with open(args.file) as f:
        params = json.load(f)
        defaults.update({k: v for k, v in vars(args).items() if v is not None})
        defaults.update(params)
        pprint.pprint(defaults)
        create_and_launch(defaults)
