# ~/.config/powerline/segments/mysegments.py
from powerline.theme import requires_segment_info

@requires_segment_info
def vpn_status(pl, segment_info):
    import subprocess
    result = subprocess.run(['ip', 'link', 'show', 'tun0'],
                           capture_output=True)
    if result.returncode == 0:
        return [{'contents': ' VPN', 'highlight_groups': ['information:regular']}]
    return None
