Export To MusicIP
====
![Min. LMS Version](https://img.shields.io/badge/Min._LMS_Version_Required-7.9-darkgreen)<br>

Plugin to export rating, play count and date last played values of your **local** music files from LMS to MusicIP.
<br><br>

> [!NOTE]
> ⚠️ **I'm not maintaining this plugin. I don't provide support for it.** And I don't use MusicIP.<br>
> If you have any problems, check out the [Lyrion Community Support Forum](https://forums.lyrion.org/).

<br><br><br>

## Screenshots[^1]

<img src="screenshots/etmip.jpg" width="100%">
<br><br><br>

## Installation

- Add the repository URL below at the bottom of *LMS* > *Settings* > *Plugins* and click *Apply*:<br>
[https://raw.githubusercontent.com/AF-1/sobras/main/repos/lmsghonly/public.xml](https://raw.githubusercontent.com/AF-1/sobras/main/repos/lmsghonly/public.xml)

- Install the plugin from the added repository at the bottom of the page.

<br><br><br><br>


## FAQ

<details><summary>»<b>How to verify in MusicIP that the export was a success</b>«</summary><br><p>
The export results can be confirmed by opening the MIP cache in the windows version of MIP. <i>Last Played</i> and <i>Ratings</i> can be added to the visible columns if not already there.<br><br>

- Cache file location:<br>

     - Windows: C:\Users\<YOUR USERNAME>\AppData\Roaming\MusicIP\MusicIP Mixer\default.m3lib<br>

     - Linux: ~/.MusicMagic
</p></details><br>

<details><summary>»<b>How to troubleshoot issues</b>«</summary><br><p>
Go to <i>LMS Settings > Advanced > Export to MusicIP</i> and set the debug level of this plugin to <i>Info</i>. Check the server.log for relevant error messages and warnings.<br>If you need to ask for support in the LMS forum, set the debug level to <i>debug</i> and include the log in your post.
</p></details><br>

<br><br>

[^1]: The screenshots might not correspond to the UI of the latest release in every detail.
