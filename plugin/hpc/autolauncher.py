from __future__ import absolute_import, division, print_function, unicode_literals
import argparse
import json
import logging
import os
import subprocess
import sys
from abc import abstractmethod
from time import strftime

root = logging.getLogger()
root.setLevel(logging.INFO)
handler = logging.StreamHandler(sys.stdout)
handler.setFormatter(logging.Formatter('%(asctime)s - %(name)s - %(levelname)s - %(message)s'))
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
        # FIX: Add Account Header if present
        if self.configuration.get('account'):
            headers.append('#SBATCH --account={account}'.format(**self.configuration))
            
        for k in ['nodes', 'cpus-per-task', 'tasks-per-node']:
            if self.configuration.get(k): headers.append(f'#SBATCH --{k}={self.configuration[k]}')
        if self.configuration.get('exclusive'): headers.append('#SBATCH --exclusive')
        return headers + self.extra_headers()

class MNLauncherWriter(SlurmLauncherWriter):
    def extra_headers(self):
        return ['#SBATCH --constraint=highmem'] if self.configuration.get('highmem') else []
    def launcher_command(self): return []

class MN5Launcher(MNLauncherWriter):
    def extra_headers(self):
        gres = int(self.configuration.get('gres') or 0)
        headers = []
        if gres > 0: headers.append('#SBATCH --gres=gpu:' + str(gres))
        return headers

    def get_extra_singularity_flags(self):
        gres = int(self.configuration.get('gres') or 0)
        return '--nv' if gres > 0 else ''

    def launcher_command(self):
        command = ['export PYTHONPATH=src', 'unset TMPDIR']
        SINGULARITY_PATH = 'apptainer'
        SINGULARITY_BINDINGS = ['/gpfs/projects/bsc70/hpai/storage/data/:/gpfs/projects/bsc70/hpai/storage/data/']
        if 'bindings_list' in self.configuration:
            SINGULARITY_BINDINGS += self.configuration['bindings_list']
        SINGULARITY_BINDINGS_CMD = ' '.join("-B {}".format(bind) for bind in SINGULARITY_BINDINGS)
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

LAUNCHER_WRITERS = {'mn4': MNLauncherWriter, 'mn5': MN5Launcher, 'local': MNLauncherWriter}

def create_and_launch(params):
    if not params.get('launchers_dir'): params['launchers_dir'] = os.path.join(params['workdir'], 'launchers')
    if not params.get('output_dir'): params['output_dir'] = os.path.join(params['workdir'], 'output')
    
    num = 0
    while True:
        job_name = (params.get('job_name', 'job') + '_{:03d}'.format(num))
        filename = 'launcher_' + job_name + '.cmd'
        filepath = os.path.join(params['launchers_dir'], filename)
        if not os.path.exists(filepath): break
        num += 1
    
    params['launcher_filepath'] = filepath
    params['output_filename'] = os.path.join(params['output_dir'], job_name)
    params['error_filename'] = os.path.join(params['output_dir'], job_name)
    
    for k in ['launchers_dir', 'output_dir']:
        if not os.path.exists(params[k]): os.makedirs(params[k])

    launcher = LAUNCHER_WRITERS[params['cluster']](params)
    with open(params['launcher_filepath'], 'w') as f:
        f.write(launcher.launcher_code())

    if not params.get('nolaunch'):
        cmd = 'sbatch ' + params['launcher_filepath']
        root.info(subprocess.check_output(cmd, shell=True))

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('-f', '--file')
    parser.add_argument('--cluster')
    args = parser.parse_args()
    
    with open(args.file) as f:
        params = json.load(f)
        params.update({k: v for k, v in vars(args).items() if v is not None})
        create_and_launch(params)
