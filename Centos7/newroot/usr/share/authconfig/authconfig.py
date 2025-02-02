#!/usr/bin/python
# -*- coding: UTF-8 -*-
#
# Authconfig - client authentication configuration program
# Copyright (c) 1999-2008 Red Hat, Inc.
#
# Original authors: Preston Brown <pbrown@redhat.com>
#                   Nalin Dahyabhai <nalin@redhat.com>
#                   Matt Wilson <msw@redhat.com>
# Python rewrite and further development by: Tomas Mraz <tmraz@redhat.com>
#
# This is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software Foundation,
# Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA

import authinfo, acutil
import gettext, os, signal, sys
_ = gettext.lgettext
from optparse import OptionParser, IndentedHelpFormatter
import locale

try:
	locale.setlocale(locale.LC_ALL, '')
except locale.Error:
	sys.stderr.write('Warning: Unsupported locale setting.\n')

def runsAs(name):
	return sys.argv[0].find(name) >= 0

if runsAs("authconfig-tui"):
	import snack

class UnihelpOptionParser(OptionParser):
	def print_help(self, file=None):
		if file is None:
			file = sys.stdout
		srcencoding = locale.getpreferredencoding()
		encoding = getattr(file, "encoding", None)
		if not encoding or encoding == "ascii":
			encoding = srcencoding
		file.write(self.format_help().decode(srcencoding).encode(encoding, "replace"))

class NonWrapFormatter(IndentedHelpFormatter):
	def format_option(self, option):
	        # The help for each option consists of two parts:
	        #   * the opt strings and metavars
	        #     eg. ("-x", or "-fFILENAME, --file=FILENAME")
	        #   * the user-supplied help string
	        #     eg. ("turn on expert mode", "read data from FILENAME")
	        #
	        # If possible, we write both of these on the same line:
	        #   -x      turn on expert mode
	        #
	        # But if the opt string list is too long, we put the help
	        # string on a second line, indented to the same column it would
	        # start in if it fit on the first line.
	        #   -fFILENAME, --file=FILENAME
	        #           read data from FILENAME
		# We cannot wrap the help text as it can be in any language and
                # encoding and so we do not know how to wrap it correctly.
	        result = []
	        opts = self.option_strings[option]
	        opt_width = self.help_position - self.current_indent - 2
	        if len(opts) > opt_width:
	            opts = "%*s%s\n" % (self.current_indent, "", opts)
	            indent_first = self.help_position
	        else:                       # start help on same line as opts
	            opts = "%*s%-*s  " % (self.current_indent, "", opt_width, opts)
	            opts = "%*s%-*s  " % (self.current_indent, "", opt_width, opts)
	            indent_first = 0
	        result.append(opts)
	        if option.help:
	            help_text = self.expand_default(option)
	            result.append("%*s%s\n" % (indent_first, "", help_text))
	        elif opts[-1] != "\n":
	            result.append("\n")
	        return "".join(result)

class Authconfig:
	def __init__(self):
		self.nis_avail = False
		self.kerberos_avail = False
		self.ldap_avail = False
		self.sssd_avail = False
		self.cache_avail = False
		self.fprintd_avail = False
		self.retval = 0

	def module(self):
		return "authconfig"

	def printError(self, error):
		sys.stderr.write("%s: %s\n" % (self.module(), error))

	def listHelp(self, l, addidx):
		idx = 0
		help = "<"
		for item in l:
			if idx > 0:
				help += "|"
			if addidx:
				help += str(idx) + "="
			help += item
			idx += 1
		help += ">"
		return help

	def parseOptions(self):
		usage = _("usage: %s [options]") % self.module()
		if self.module() == "authconfig":
			usage += " {--update|--updateall|--test|--probe|--restorebackup <name>|--savebackup <name>|--restorelastbackup}"

		parser = UnihelpOptionParser(usage, add_help_option=False, formatter=NonWrapFormatter())
		parser.add_option("-h", "--help", action="help",
			help=_("show this help message and exit"))

		parser.add_option("--enableshadow", "--useshadow", action="store_true",
			help=_("enable shadowed passwords by default"))
		parser.add_option("--disableshadow", action="store_true",
			help=_("disable shadowed passwords by default"))
		parser.add_option("--enablemd5", "--usemd5", action="store_true",
			help=_("enable MD5 passwords by default"))
		parser.add_option("--disablemd5", action="store_true",
			help=_("disable MD5 passwords by default"))
		parser.add_option("--passalgo",
			metavar=self.listHelp(authinfo.password_algorithms, False),
			help=_("hash/crypt algorithm for new passwords"))

		parser.add_option("--enablenis", action="store_true",
			help=_("enable NIS for user information by default"))
		parser.add_option("--disablenis", action="store_true",
			help=_("disable NIS for user information by default"))
		parser.add_option("--nisdomain", metavar=_("<domain>"),
			help=_("default NIS domain"))
		parser.add_option("--nisserver", metavar=_("<server>"),
			help=_("default NIS server"))

		parser.add_option("--enableldap", action="store_true",
			help=_("enable LDAP for user information by default"))
		parser.add_option("--disableldap", action="store_true",
			help=_("disable LDAP for user information by default"))
		parser.add_option("--enableldapauth", action="store_true",
			help=_("enable LDAP for authentication by default"))
		parser.add_option("--disableldapauth", action="store_true",
			help=_("disable LDAP for authentication by default"))
		parser.add_option("--ldapserver", metavar=_("<server>"),
			help=_("default LDAP server hostname or URI"))
		parser.add_option("--ldapbasedn", metavar=_("<dn>"),
			help=_("default LDAP base DN"))
		parser.add_option("--enableldaptls", "--enableldapstarttls", action="store_true",
			help=_("enable use of TLS with LDAP (RFC-2830)"))
		parser.add_option("--disableldaptls",  "--disableldapstarttls", action="store_true",
			help=_("disable use of TLS with LDAP (RFC-2830)"))
		parser.add_option("--enablerfc2307bis", action="store_true",
			help=_("enable use of RFC-2307bis schema for LDAP user information lookups"))
		parser.add_option("--disablerfc2307bis", action="store_true",
			help=_("disable use of RFC-2307bis schema for LDAP user information lookups"))
		parser.add_option("--ldaploadcacert", metavar=_("<URL>"),
			help=_("load CA certificate from the URL"))

		parser.add_option("--enablesmartcard", action="store_true",
			help=_("enable authentication with smart card by default"))
		parser.add_option("--disablesmartcard", action="store_true",
			help=_("disable authentication with smart card by default"))
		parser.add_option("--enablerequiresmartcard", action="store_true",
			help=_("require smart card for authentication by default"))
		parser.add_option("--disablerequiresmartcard", action="store_true",
			help=_("do not require smart card for authentication by default"))
		parser.add_option("--smartcardmodule", metavar=_("<module>"),
			help=_("default smart card module to use"))
		actshelp = self.listHelp(authinfo.getSmartcardActions(), True)
		parser.add_option("--smartcardaction", metavar=actshelp,
			help=_("action to be taken on smart card removal"))

		parser.add_option("--enablefingerprint", action="store_true",
			help=_("enable authentication with fingerprint readers by default"))
		parser.add_option("--disablefingerprint", action="store_true",
			help=_("disable authentication with fingerprint readers by default"))

		parser.add_option("--enableecryptfs", action="store_true",
			help=_("enable automatic per-user ecryptfs"))
		parser.add_option("--disableecryptfs", action="store_true",
			help=_("disable automatic per-user ecryptfs"))

		parser.add_option("--enablekrb5", action="store_true",
			help=_("enable kerberos authentication by default"))
		parser.add_option("--disablekrb5", action="store_true",
			help=_("disable kerberos authentication by default"))
		parser.add_option("--krb5kdc", metavar=_("<server>"),
			help=_("default kerberos KDC"))
		parser.add_option("--krb5adminserver", metavar=_("<server>"),
			help=_("default kerberos admin server"))
		parser.add_option("--krb5realm", metavar=_("<realm>"),
			help=_("default kerberos realm"))
		parser.add_option("--enablekrb5kdcdns", action="store_true",
			help=_("enable use of DNS to find kerberos KDCs"))
		parser.add_option("--disablekrb5kdcdns", action="store_true",
			help=_("disable use of DNS to find kerberos KDCs"))
		parser.add_option("--enablekrb5realmdns", action="store_true",
			help=_("enable use of DNS to find kerberos realms"))
		parser.add_option("--disablekrb5realmdns", action="store_true",
			help=_("disable use of DNS to find kerberos realms"))

		parser.add_option("--enablewinbind", action="store_true",
			help=_("enable winbind for user information by default"))
		parser.add_option("--disablewinbind", action="store_true",
			help=_("disable winbind for user information by default"))
		parser.add_option("--enablewinbindauth", action="store_true",
			help=_("enable winbind for authentication by default"))
		parser.add_option("--disablewinbindauth", action="store_true",
			help=_("disable winbind for authentication by default"))
		parser.add_option("--smbsecurity", metavar="<user|server|domain|ads>",
			help=_("security mode to use for samba and winbind"))
		parser.add_option("--smbrealm", metavar=_("<realm>"),
			help=_("default realm for samba and winbind when security=ads"))
		parser.add_option("--smbservers", metavar=_("<servers>"),
			help=_("names of servers to authenticate against"))
		parser.add_option("--smbworkgroup", metavar=_("<workgroup>"),
			help=_("workgroup authentication servers are in"))
		parser.add_option("--smbidmaprange", "--smbidmapuid", "--smbidmapgid", metavar=_("<lowest-highest>"),
			help=_("uid range winbind will assign to domain or ads users"))
		parser.add_option("--winbindseparator", metavar="<\\>",
			help=_("the character which will be used to separate the domain and user part of winbind-created user names if winbindusedefaultdomain is not enabled"))
		parser.add_option("--winbindtemplatehomedir", metavar="</home/%D/%U>",
			help=_("the directory which winbind-created users will have as home directories"))
		parser.add_option("--winbindtemplateshell", metavar="</bin/false>",
			help=_("the shell which winbind-created users will have as their login shell"))
		parser.add_option("--enablewinbindusedefaultdomain", action="store_true",
			help=_("configures winbind to assume that users with no domain in their user names are domain users"))
		parser.add_option("--disablewinbindusedefaultdomain", action="store_true",
			help=_("configures winbind to assume that users with no domain in their user names are not domain users"))
		parser.add_option("--enablewinbindoffline", action="store_true",
			help=_("configures winbind to allow offline login"))
		parser.add_option("--disablewinbindoffline", action="store_true",
			help=_("configures winbind to prevent offline login"))
		parser.add_option("--enablewinbindkrb5", action="store_true",
			help=_("winbind will use Kerberos 5 to authenticate"))
		parser.add_option("--disablewinbindkrb5", action="store_true",
			help=_("winbind will use the default authentication method"))
		parser.add_option("--winbindjoin", metavar="<Administrator>",
			help=_("join the winbind domain or ads realm now as this administrator"))

		parser.add_option("--enableipav2", action="store_true",
			help=_("enable IPAv2 for user information and authentication by default"))
		parser.add_option("--disableipav2", action="store_true",
			help=_("disable IPAv2 for user information and authentication by default"))
		parser.add_option("--ipav2domain", metavar=_("<domain>"),
			help=_("the IPAv2 domain the system should be part of"))
		parser.add_option("--ipav2realm", metavar=_("<realm>"),
			help=_("the realm for the IPAv2 domain"))
		parser.add_option("--ipav2server", metavar=_("<servers>"),
			help=_("the server for the IPAv2 domain"))
		parser.add_option("--enableipav2nontp", action="store_true",
			help=_("do not setup the NTP against the IPAv2 domain"))
		parser.add_option("--disableipav2nontp", action="store_true",
			help=_("setup the NTP against the IPAv2 domain (default)"))
		parser.add_option("--ipav2join", metavar="<account>",
			help=_("join the IPAv2 domain as this account"))

		parser.add_option("--enablewins", action="store_true",
			help=_("enable wins for hostname resolution"))
		parser.add_option("--disablewins", action="store_true",
			help=_("disable wins for hostname resolution"))

		parser.add_option("--enablepreferdns", action="store_true",
			help=_("prefer dns over wins or nis for hostname resolution"))
		parser.add_option("--disablepreferdns", action="store_true",
			help=_("do not prefer dns over wins or nis for hostname resolution"))

		parser.add_option("--enablehesiod", action="store_true",
			help=_("enable hesiod for user information by default"))
		parser.add_option("--disablehesiod", action="store_true",
			help=_("disable hesiod for user information by default"))
		parser.add_option("--hesiodlhs", metavar="<lhs>",
			help=_("default hesiod LHS"))
		parser.add_option("--hesiodrhs", metavar="<rhs>",
			help=_("default hesiod RHS"))

		parser.add_option("--enablesssd", action="store_true",
			help=_("enable SSSD for user information by default with manually managed configuration"))
		parser.add_option("--disablesssd", action="store_true",
			help=_("disable SSSD for user information by default (still used for supported configurations)"))
		parser.add_option("--enablesssdauth", action="store_true",
			help=_("enable SSSD for authentication by default with manually managed configuration"))
		parser.add_option("--disablesssdauth", action="store_true",
			help=_("disable SSSD for authentication by default (still used for supported configurations)"))
		parser.add_option("--enableforcelegacy", action="store_true",
			help=_("never use SSSD implicitly even for supported configurations"))
		parser.add_option("--disableforcelegacy", action="store_true",
			help=_("use SSSD implicitly if it supports the configuration"))

		parser.add_option("--enablecachecreds", action="store_true",
			help=_("enable caching of user credentials in SSSD by default"))
		parser.add_option("--disablecachecreds", action="store_true",
			help=_("disable caching of user credentials in SSSD by default"))

		parser.add_option("--enablecache", action="store_true",
			help=_("enable caching of user information by default (automatically disabled when SSSD is used)"))
		parser.add_option("--disablecache", action="store_true",
			help=_("disable caching of user information by default"))

		parser.add_option("--enablelocauthorize", action="store_true",
			help=_("local authorization is sufficient for local users"))
		parser.add_option("--disablelocauthorize", action="store_true",
			help=_("authorize local users also through remote service"))

		parser.add_option("--enablepamaccess", action="store_true",
			help=_("check access.conf during account authorization"))
		parser.add_option("--disablepamaccess", action="store_true",
			help=_("do not check access.conf during account authorization"))

		parser.add_option("--enablesysnetauth", action="store_true",
			help=_("authenticate system accounts by network services"))
		parser.add_option("--disablesysnetauth", action="store_true",
			help=_("authenticate system accounts by local files only"))

		parser.add_option("--enablemkhomedir", action="store_true",
			help=_("create home directories for users on their first login"))
		parser.add_option("--disablemkhomedir", action="store_true",
			help=_("do not create home directories for users on their first login"))

                parser.add_option("--passminlen", metavar=_("<number>"),
                        help=_("minimum length of a password"))
                parser.add_option("--passminclass", metavar=_("<number>"),
                        help=_("minimum number of character classes in a password"))
                parser.add_option("--passmaxrepeat", metavar=_("<number>"),
                        help=_("maximum number of same consecutive characters in a password"))
                parser.add_option("--passmaxclassrepeat", metavar=_("<number>"),
                        help=_("maximum number of consecutive characters of same class in a password"))
                parser.add_option("--enablereqlower", action="store_true",
                        help=_("require at least one lowercase character in a password"))
                parser.add_option("--disablereqlower", action="store_true",
                        help=_("do not require lowercase characters in a password"))
                parser.add_option("--enablerequpper", action="store_true",
                        help=_("require at least one uppercase character in a password"))
                parser.add_option("--disablerequpper", action="store_true",
                        help=_("do not require uppercase characters in a password"))
                parser.add_option("--enablereqdigit", action="store_true",
                        help=_("require at least one digit in a password"))
                parser.add_option("--disablereqdigit", action="store_true",
                        help=_("do not require digits in a password"))
                parser.add_option("--enablereqother", action="store_true",
                        help=_("require at least one other character in a password"))
                parser.add_option("--disablereqother", action="store_true",
                        help=_("do not require other characters in a password"))
                
		parser.add_option("--enablefaillock", action="store_true",
			help=_("enable account locking in case of too many consecutive authentication failures"))
		parser.add_option("--disablefaillock", action="store_true",
			help=_("disable account locking on too many consecutive authentication failures"))
		parser.add_option("--faillockargs", metavar=_("<options>"),
			help=_("the pam_faillock module options"))

		parser.add_option("--nostart", action="store_true",
			help=_("do not start/stop portmap, ypbind, and nscd"))

		parser.add_option("--test", action="store_true",
			help=_("do not update the configuration files, only print new settings"))

		if self.module() == "authconfig-tui":
			parser.add_option("--back", action="store_true",
				help=_("display Back instead of Cancel in the main dialog of the TUI"))
			parser.add_option("--kickstart", action="store_true",
				help=_("do not display the deprecated text user interface"))
		else:
			parser.add_option("--update", "--kickstart", action="store_true",
				help=_("opposite of --test, update configuration files with changed settings"))

		parser.add_option("--updateall", action="store_true",
			help=_("update all configuration files"))

		parser.add_option("--probe", action="store_true",
			help=_("probe network for defaults and print them"))

		parser.add_option("--savebackup", metavar=_("<name>"),
			help=_("save a backup of all configuration files"))

		parser.add_option("--restorebackup", metavar=_("<name>"),
			help=_("restore the backup of configuration files"))

		parser.add_option("--restorelastbackup", action="store_true",
			help=_("restore the backup of configuration files saved before the previous configuration change"))

		(self.options, args) = parser.parse_args()

		if args:
			self.printError(_("unexpected argument"))
			sys.exit(2)

		if (not self.module() == "authconfig-tui" and not self.options.probe and
			not self.options.test and not self.options.update and not self.options.updateall
			and not self.options.savebackup and not self.options.restorebackup
			and not self.options.restorelastbackup):
			# --update (== --kickstart) or --test or --probe must be specified
			# this will print usage and call sys.exit()
			parser.print_help()
			sys.exit(2)

	def probe(self):
		info = authinfo.AuthInfo(self.printError)
		info.probe()
		if info.hesiodLHS and info.hesiodRHS:
			print "hesiod %s/%s" % (info.hesiodLHS,
				info.hesiodRHS)
		if info.ldapServer and info.ldapBaseDN:
			print "ldap %s/%s\n" % (info.ldapServer,
				info.ldapBaseDN)
		if info.kerberosRealm:
			print "krb5 %s/%s/%s\n" % (info.kerberosRealm,
				info.kerberosKDC or "", info.kerberosAdminServer or "")

	def readAuthInfo(self):
		self.info = authinfo.read(self.printError)
		# FIXME: what about printing critical errors reading individual configs?
		self.pristineinfo = self.info.copy()
		if self.info.enableLocAuthorize == None:
			self.info.enableLocAuthorize = True # ON by default

	def testAvailableSubsys(self):
		self.nis_avail = (os.access(authinfo.PATH_YPBIND, os.X_OK) and
			os.access(authinfo.PATH_LIBNSS_NIS, os.X_OK))
		self.kerberos_avail = os.access(authinfo.PATH_PAM_KRB5, os.X_OK)
		self.ldap_avail = (os.access(authinfo.PATH_PAM_LDAP, os.X_OK) and
			os.access(authinfo.PATH_LIBNSS_LDAP, os.X_OK))
		self.sssd_avail = (os.access(authinfo.PATH_PAM_SSS, os.X_OK) and
			os.access(authinfo.PATH_LIBNSS_SSS, os.X_OK))
		self.cache_avail = os.access(authinfo.PATH_NSCD, os.X_OK)
		self.fprintd_avail = os.access(authinfo.PATH_PAM_FPRINTD, os.X_OK)

	def overrideSettings(self):
		bool_settings = {"shadow":"enableShadow",
			"locauthorize":"enableLocAuthorize",
			"pamaccess":"enablePAMAccess",
			"sysnetauth":"enableSysNetAuth",
			"mkhomedir":"enableMkHomeDir",
			"cache":"enableCache",
			"ecryptfs":"enableEcryptfs",
			"hesiod":"enableHesiod",
			"ldap":"enableLDAP",
			"ldaptls":"enableLDAPS",
			"rfc2307bis":"enableRFC2307bis",
			"ldapauth":"enableLDAPAuth",
			"krb5":"enableKerberos",
			"nis":"enableNIS",
			"krb5kdcdns":"kerberosKDCviaDNS",
			"krb5realmdns":"kerberosRealmviaDNS",
			"smartcard":"enableSmartcard",
			"fingerprint":"enableFprintd",
			"requiresmartcard":"forceSmartcard",
			"winbind":"enableWinbind",
			"winbindauth":"enableWinbindAuth",
			"winbindusedefaultdomain":"winbindUseDefaultDomain",
			"winbindoffline":"winbindOffline",
			"winbindkrb5":"winbindKrb5",
			"ipav2":"enableIPAv2",
			"ipav2nontp":"ipav2NoNTP",
			"wins":"enableWINS",
			"sssd":"enableSSSD",
			"sssdauth":"enableSSSDAuth",
			"forcelegacy":"enableForceLegacy",
			"cachecreds":"enableCacheCreds",
			"preferdns":"preferDNSinHosts",
                        "reqlower":"passReqLower",
                        "requpper":"passReqUpper",
                        "reqdigit":"passReqDigit",
                        "reqother":"passReqOther",
			"faillock":"enableFaillock"}

		string_settings = {"passalgo":"passwordAlgorithm",
			"hesiodlhs":"hesiodLHS",
			"hesiodrhs":"hesiodRHS",
			"ldapserver":"ldapServer",
			"ldapbasedn":"ldapBaseDN",
			"ldaploadcacert":"ldapCacertURL",
			"krb5realm":"kerberosRealm",
			"krb5kdc":"kerberosKDC",
			"krb5adminserver":"kerberosAdminServer",
			"smartcardmodule":"smartcardModule",
			"smartcardaction":"smartcardAction",
			"nisdomain":"nisDomain",
			"nisserver":"nisServer",
			"smbworkgroup":"smbWorkgroup",
			"smbservers":"smbServers",
			"smbsecurity":"smbSecurity",
			"smbrealm" : "smbRealm",
			"smbidmaprange":"smbIdmapRange",
			"winbindseparator":"winbindSeparator",
			"winbindtemplatehomedir":"winbindTemplateHomedir",
			"winbindtemplateshell":"winbindTemplateShell",
			"ipav2domain":"ipav2Domain",
			"ipav2realm":"ipav2Realm",
			"ipav2server":"ipav2Server",
                        "passminlen":"passMinLen",
                        "passminclass":"passMinClass",
                        "passmaxrepeat":"passMaxRepeat",
                        "passmaxclassrepeat":"passMaxClassRepeat",
			"faillockargs":"faillockArgs"}

		for opt, aival in bool_settings.iteritems():
			if getattr(self.options, "enable"+opt):
				setattr(self.info, aival, True)
			if getattr(self.options, "disable"+opt):
				setattr(self.info, aival, False)

		try:
			if self.info.enableRFC2307bis:
				self.info.ldapSchema = 'rfc2307bis'
			else:
				self.info.ldapSchema = ''
		except AttributeError:
			pass

		if self.options.krb5realm and self.options.krb5realm != self.info.kerberosRealm:
			self.info.kerberosKDC = self.info.getKerberosKDC(self.options.krb5realm)
			self.info.kerberosAdminServer = self.info.getKerberosAdminServer(self.options.krb5realm)

                try:
            		val = self.options.passminlen
            		if val != None:
            			val = int(val)
            			if val < 6:
            				self.printError(_("The passminlen minimum value is 6"))
            				self.options.passminlen = None
            				self.retval = 3
                except ValueError:
                        self.printError(_("The passminlen option value is not an integer"))
                        self.options.passminlen = None
                        self.retval = 3
                try:
            		val = self.options.passminclass
            		if val != None:
            			val = int(val)
            			if val < 0:
            				self.printError(_("The passminclass value must not be negative"))
            				self.options.passminclass = None
            				self.retval = 3
            			if val > 4:
            				self.printError(_("The passminclass value must not be higher than 4"))
            				self.options.passminclass = None
            				self.retval = 3
                except ValueError:
                        self.printError(_("The passminclass option value is not an integer"))
                        self.options.passminclass = None
                        self.retval = 3
                try:
            		val = self.options.passmaxrepeat
            		if val != None:
            			val = int(val)
            			if val < 0:
            				self.printError(_("The passmaxrepeat value must not be negative"))
            				self.options.passmaxrepeat = None
            				self.retval = 3
                except ValueError:
                        self.printError(_("The passmaxrepeat option value is not an integer"))
                        self.options.passmaxrepeat = None
                        self.retval = 3
                try:
            		val = self.options.passmaxclassrepeat
            		if val != None:
            			val = int(val)
            			if val < 0:
            				self.printError(_("The passmaxclassrepeat value must not be negative"))
            				self.options.passmaxclassrepeat = None
            				self.retval = 3
                except ValueError:
                        self.printError(_("The passmaxclassrepeat option value is not an integer"))
                        self.options.passmaxclassrepeat = None
                        self.retval = 3

		for opt, aival in string_settings.iteritems():
			if getattr(self.options, opt) != None:
				setattr(self.info, aival, getattr(self.options, opt))

		if self.options.winbindjoin:
			lst = self.options.winbindjoin.split("%", 1)
			self.info.joinUser = lst[0]
			if len(lst) > 1:
				self.info.joinPassword = lst[1]

		if self.options.ipav2join != None:
			self.info.joinUser = self.options.ipav2join

		if self.options.smartcardaction:
			try:
				idx = int(self.options.smartcardaction)
				self.info.smartcardAction = authinfo.getSmartcardActions()[idx]
			except (ValueError, IndexError):
				self.printError(_("Bad smart card removal action specified."))
				self.info.smartcardAction = ""

		if self.options.enablerequiresmartcard and self.options.smartcardmodule == "sssd":
			self.printError(_("--enablerequiresmartcard is not supported for module 'sssd', option is ignored."))
			self.options.enablerequiresmartcard = False

		if not self.options.passalgo:
			if self.options.enablemd5:
				self.info.passwordAlgorithm = "md5"
			if self.options.disablemd5:
				self.info.passwordAlgorithm = "descrypt"
		elif self.options.passalgo not in authinfo.password_algorithms:
			self.printError(_("Unknown password hashing algorithm specified, using sha256."))
			self.info.passwordAlgorithm = "sha256"
			self.retval = 3

	def doUI(self):
		return True

	def joinDomain(self):
		ret = True
		if self.options.winbindjoin:
			ret = self.info.joinDomain(True)
		if self.options.ipav2join != None:
			if self.info.joinIPADomain(True):
				# This is a hack but otherwise we cannot
				# get the IPAV2DOMAINJOINED saved
				# unfortunately the backup will be overwritten
				self.info.writeSysconfig()
			else:
				ret = False
		return ret

	def writeAuthInfo(self):
		self.info.testLDAPCACerts()
		if self.info.ldapCacertURL:
			if not self.info.downloadLDAPCACert():
				self.retval = 4
		self.info.rehashLDAPCACerts()
		if self.options.updateall:
			if not self.info.write():
				self.retval = 5
		else:
			if not self.info.writeChanged(self.pristineinfo):
				self.retval = 6
		# FIXME: what about printing critical errors writing individual configs?
		if not self.joinDomain():
			self.retval = 7
		self.info.post(self.options.nostart)

	def run(self):
		self.parseOptions()
		if self.options.probe:
			self.probe()
			sys.exit(0)
		if not self.options.test and os.getuid() != 0:
			self.printError(_("can only be run as root"))
			sys.exit(2)
		self.readAuthInfo()
		if self.options.restorelastbackup:
			rv = self.info.restoreLast()
			sys.exit(int(not rv))
		if self.options.restorebackup:
			rv = self.info.restoreBackup(self.options.restorebackup)
			sys.exit(int(not rv))
		if self.options.savebackup:
			rv = self.info.saveBackup(self.options.savebackup)
			sys.exit(int(not rv))
		self.testAvailableSubsys()
		self.overrideSettings()
		if not self.doUI():
			if self.options.test:
				self.printError(_("dialog was cancelled"))
			sys.exit(1)
		if self.options.test:
			self.info.printInfo()
		else:
			self.writeAuthInfo()
		return self.retval

class AuthconfigTUI(Authconfig):
	def module(self):
		return "authconfig-tui"

	def joinDomain(self):
		# join domain only on kickstart
		if self.options.kickstart and self.options.winbindjoin:
			self.info.joinDomain(True)

	def warn(self, toggle, warning):
		if not toggle:
			return

		while warning:
			path = warning[0]
			package = warning[2]
			if type(path) == tuple:
				if self.info.sssdSupported():
					path = path[1]
					package = package[1]
				else:
					path = path[0]
					package = package[0]
			if not os.access(path, os.R_OK):
				text = (_("The %s file was not found, but it is required for %s support to work properly.\nInstall the %s package, which provides this file.") %
					(path, warning[1], package))
				snack.ButtonChoiceWindow(self.screen, _("Warning"), text, [_("Ok")])
			warning = warning[3]

	def getMainChoices(self):
		warnCache = [authinfo.PATH_NSCD, _("caching"), "nscd", None]
		warnFprintd = [authinfo.PATH_PAM_FPRINTD, _("Fingerprint reader"), "pam_fprintd", None]
		warnKerberos = [(authinfo.PATH_PAM_KRB5, authinfo.PATH_PAM_SSS), _("Kerberos"), ("pam_krb5", "sssd-client"), None]
		warnLDAPAuth = [(authinfo.PATH_PAM_LDAP, authinfo.PATH_PAM_SSS), _("LDAP authentication"), ("pam_ldap", "sssd-client"), None]
		warnLDAP = [(authinfo.PATH_LIBNSS_LDAP, authinfo.PATH_LIBNSS_SSS), _("LDAP"), ("nss-pam-ldapd", "sssd-client"), None]
		warnNIS = [authinfo.PATH_YPBIND, _("NIS"), "ypbind", None]
		warnShadow = [authinfo.PATH_PWCONV, _("shadow password"), "shadow-utils", None]
		warnWinbindNet = [authinfo.PATH_WINBIND_NET, _("Winbind"), "samba-client", None]
		warnWinbindAuth = [authinfo.PATH_PAM_WINBIND, _("Winbind authentication"), "samba-winbind", warnWinbindNet]
		warnWinbind = [authinfo.PATH_LIBNSS_WINBIND, _("Winbind"), "samba-winbind", warnWinbindAuth]

		# Information
		infoGrid = snack.Grid(1, 6)

		comp = snack.Label(_("User Information"))
		infoGrid.setField(comp, 0, 0, anchorLeft=1, growx=1)

		cache = cb = snack.Checkbox(_("Cache Information"), bool(self.info.enableCache))
		infoGrid.setField(cb, 0, 1, anchorLeft=1, growx=1)

		ldap = cb = snack.Checkbox(_("Use LDAP"), bool(self.info.enableLDAP))
		infoGrid.setField(cb, 0, 2, anchorLeft=1, growx=1)

		nis = cb = snack.Checkbox(_("Use NIS"), bool(self.info.enableNIS))
		infoGrid.setField(cb, 0, 3, anchorLeft=1, growx=1)

		ipav2 = cb = snack.Checkbox(_("Use IPAv2"), bool(self.info.enableIPAv2))
		infoGrid.setField(cb, 0, 4, anchorLeft=1, growx=1)

		winbind = cb = snack.Checkbox(_("Use Winbind"), bool(self.info.enableWinbind))
		infoGrid.setField(cb, 0, 5, anchorLeft=1, growx=1)

		# Authentication
		authGrid = snack.Grid(1, 8)

		comp = snack.Label(_("Authentication"))
		authGrid.setField(comp, 0, 0, anchorLeft=1, growx=1)

		md5 = cb = snack.Checkbox(_("Use MD5 Passwords"), bool(self.info.passwordAlgorithm=='md5'))
		authGrid.setField(cb, 0, 1, anchorLeft=1, growx=1)

		shadow = cb = snack.Checkbox(_("Use Shadow Passwords"), bool(self.info.enableShadow))
		authGrid.setField(cb, 0, 2, anchorLeft=1, growx=1)

		ldapa = cb = snack.Checkbox(_("Use LDAP Authentication"), bool(self.info.enableLDAPAuth))
		authGrid.setField(cb, 0, 3, anchorLeft=1, growx=1)

		krb5 = cb = snack.Checkbox(_("Use Kerberos"), bool(self.info.enableKerberos))
		authGrid.setField(cb, 0, 4, anchorLeft=1, growx=1)

		fprintd = cb = snack.Checkbox(_("Use Fingerprint reader"), bool(self.info.enableFprintd))
		authGrid.setField(cb, 0, 5, anchorLeft=1, growx=1)


		winbindauth = cb = snack.Checkbox(_("Use Winbind Authentication"), bool(self.info.enableWinbindAuth))
		authGrid.setField(cb, 0, 6, anchorLeft=1, growx=1)

		locauthorize = cb = snack.Checkbox(_("Local authorization is sufficient"), bool(self.info.enableLocAuthorize))
		authGrid.setField(cb, 0, 7, anchorLeft=1, growx=1)

		# Control grid
		mechGrid = snack.Grid(2, 1)
		mechGrid.setField(infoGrid, 0, 0, anchorLeft=1, anchorTop=1, padding=(1, 0, 1, 1))
		mechGrid.setField(authGrid, 1, 0, anchorRight=1, anchorTop=1, padding=(2, 0, 1, 1))

		# Buttons
		buttonGrid = snack.Grid(2, 1)
		cancel = snack.Button(self.options.back and _("Back") or _("Cancel"))
		ok = snack.Button(_("Next"))
		buttonGrid.setField(cancel, 0, 0)
		buttonGrid.setField(ok, 1, 0)

		# Top-level grid
		mainGrid = snack.Grid(1, 2)
		mainGrid.setField(mechGrid, 0, 0, growx=1)
		mainGrid.setField(buttonGrid, 0, 1, growx=1)

		# Run the form and interpret the results
		form = snack.Form()
		self.screen.gridWrappedWindow(mainGrid, _("Authentication Configuration"))
		form.add(mainGrid)

		# BEHOLD!  AUTHCONFIG IN ALL ITS GORY GLORY!
		comp = form.run()

		if comp != cancel:
			self.info.enableCache = cache.selected()
			self.info.enableIPAv2 = ipav2.selected()
			self.info.enableLDAP = ldap.selected()
			self.info.enableNIS = nis.selected()
			self.info.enableWinbind = winbind.selected()
			self.info.enableShadow = shadow.selected()
			if md5.selected():
				self.info.passwordAlgorithm = 'md5'
			elif self.info.passwordAlgorithm == 'md5':
				self.info.passwordAlgorithm = 'descrypt'
			self.info.enableLDAPAuth = ldapa.selected()
			self.info.enableKerberos = krb5.selected()
			self.info.enableWinbindAuth = winbindauth.selected()
			self.info.enableLocAuthorize = locauthorize.selected()
			self.info.enableFprintd = fprintd.selected()
			allwarnings = [(self.info.enableCache, warnCache), (self.info.enableLDAP, warnLDAP),
				(self.info.enableNIS, warnNIS), (self.info.enableWinbind, warnWinbind),
				(self.info.enableLDAPAuth, warnLDAPAuth), (self.info.enableKerberos, warnKerberos),
				(self.info.enableFprintd, warnFprintd), (self.info.enableShadow, warnShadow),
				(self.info.enableWinbindAuth, warnWinbindAuth)]
			for warning in allwarnings:
				self.warn(warning[0], warning[1])

		self.screen.popWindow()

		return comp != cancel

	def getGenericChoices(self, dtitle, items, canceltxt, oktxt, anothertxt=None, anothercb=None):

		# Count up the number of rows we need in the grid.
		rows = len(items)

		# Create a grid for these questions.
		questionGrid = snack.Grid(2, rows)
		row = 0
		widgets = []
		for (t, desc, attr, val) in items:
			if t == "tfvalue":
				cb = snack.Checkbox(desc, bool(getattr(self.info, attr)))
				widgets.append(cb)
				questionGrid.setField(snack.Label(""), 0, row, anchorRight=1)
				questionGrid.setField(cb, 1, row, anchorLeft=1)

			elif t == "svalue":
				comp = snack.Label(desc)
				questionGrid.setField(comp, 0, row, padding=(0, 0, 1, 0), anchorRight=1)
				comp = snack.Entry(40, getattr(self.info, attr), hidden=val)
				widgets.append(comp)
				# FIXME? Filtering " " and "\t"
				questionGrid.setField(comp, 1, row, growx=1)

			elif t == "rvalue":
				comp = snack.Label(desc)
				questionGrid.setField(comp, 0, row, padding=(0, 0, 1, 0), anchorRight=1, anchorTop=1)
				try:
					sel = getattr(self.info, attr)
					val.index(sel)
				except ValueError:
					sel = val[0]
				comp = None
				buttonlist = []
				for v in val:
					buttonlist.append((v, v, v == sel))
				radioBar = snack.RadioBar(None, buttonlist)
				widgets.append(radioBar)
				questionGrid.setField(radioBar, 1, row, anchorLeft=1)

			elif t == "lvalue":
				comp = snack.TextboxReflowed(50, desc, flexDown=1, flexUp=1)
				widgets.append(comp)
				questionGrid.setField(comp, 0, row, anchorLeft=1)

			row += 1

		# Buttons
		buttonGrid = snack.Grid(anothertxt and 3 or 2, 1)
		cancel = snack.Button(canceltxt)
		ok = snack.Button(oktxt)
		another = anothertxt and snack.Button(anothertxt) or None
		buttonGrid.setField(cancel, 0, 0)
		if anothertxt:
			buttonGrid.setField(another, 1, 0)
		buttonGrid.setField(ok, anothertxt and 2 or 1, 0)

		# Top-level grid
		mainGrid = snack.Grid(1, 2)
		mainGrid.setField(questionGrid, 0, 0, padding=(0, 0, 0, 1), growx=1)
		mainGrid.setField(buttonGrid, 0, 1, padding=(0, 0, 0, 0), growx=1)

		# Run the form and interpret the results
		form = snack.Form()
		self.screen.gridWrappedWindow(mainGrid, dtitle)
		form.add(mainGrid)

		while True:
			comp = form.run()
			if comp == cancel:
				break

			wcopy = widgets[:]
			for (t, desc, attr, val) in items:
				if t == "tfvalue":
					setattr(self.info, attr, wcopy.pop(0).selected())

				elif t == "svalue":
					setattr(self.info, attr, wcopy.pop(0).value())
					# FIXME? Filtering " " and "\t"

				elif t == "rvalue":
					setattr(self.info, attr, wcopy.pop(0).getSelection())

				elif t == "lvalue":
					wcopy.pop(0)

			if comp != another:
				break
			if anothercb:
				anothercb()

		self.screen.popWindow()
		return comp != cancel

	def getIPAv2Settings(self, next):
		questions = [("svalue", _("Domain:"), "ipav2Domain", 0),
			("svalue", _("Realm:"), "ipav2Realm", 0),
			("svalue", _("Server:"), "ipav2Server", 0)]
		return self.getGenericChoices(_("IPAv2 Settings"),
			questions, _("Back"), next and _("Next") or _("Ok"),
			anothertxt=_("Join Domain"), anothercb=self.maybeGetJoinSettings)

	def getLDAPSettings(self, next):
		questions = [("tfvalue", _("Use TLS"), "enableLDAPS", None),
			("svalue", _("Server:"), "ldapServer", 0),
			("svalue", _("Base DN:"), "ldapBaseDN", 0)]
		return self.getGenericChoices(_("LDAP Settings"),
			questions, _("Back"), next and _("Next") or _("Ok"))

	def getNISSettings(self, next):
		questions = [("svalue", _("Domain:"), "nisDomain", 0),
			("svalue", _("Server:"), "nisServer", 0)]
		return self.getGenericChoices(_("NIS Settings"),
			questions, _("Back"), next and _("Next") or _("Ok"))

	def getKerberosSettings(self, next):
		questions = [("svalue", _("Realm:"), "kerberosRealm", 0),
			("svalue", _("KDC:"), "kerberosKDC", 0),
			("svalue", _("Admin Server:"), "kerberosAdminServer", 0),
			("tfvalue", _("Use DNS to resolve hosts to realms"), "kerberosRealmviaDNS", None),
			("tfvalue", _("Use DNS to locate KDCs for realms"), "kerberosKDCviaDNS", None)]
		return self.getGenericChoices(_("Kerberos Settings"),
			questions, _("Back"), next and _("Next") or _("Ok"))

	def getJoinSettings(self):
		questions = [("svalue", _("Domain Administrator:"), "joinUser", 0),
			("svalue", _("Password:"), "joinPassword", 1)]
		if not self.info.joinUser:
			self.info.joinUser = "Administrator"
		if self.getGenericChoices(_("Join Settings"),
			questions, _("Cancel"), _("Ok")):
			self.screen.suspend()
			self.info.update()
			if self.info.enableWinbind:
				self.info.joinDomain(True)
			elif self.info.enableIPAv2:
				self.info.joinIPADomain(True)
			self.screen.resume()
		return True

	def maybeGetJoinSettings(self):
		questions = [("lvalue",
			     _("Some of the configuration changes you've made should be saved to disk before continuing.  If you do not save them, then your attempt to join the domain may fail.  Save changes?"),
			     None, None)]
		orig_info = authinfo.read(self.printError)
		orig_info.update()
		self.info.update()
		ret = False
		if self.info.differs(orig_info):
			ret = self.getGenericChoices(_("Save Settings"),
				questions, _("No"), _("Yes"))
		if ret:
			self.info.write()
		self.getJoinSettings()
		return True

	def getWinbindSettings(self, next):
		security = ["ads", "domain"]
		shells = ["/sbin/nologin", "/bin/sh", "/bin/bash", "/bin/tcsh", "/bin/ksh",
			"/bin/zsh"]

		def shellexists(shell):
			return os.access(shell, os.X_OK)

		shells = filter(shellexists, shells)
		# Why does your favorite shell not show up in the list?  Because it won't
		# fit, that's why!
		questions = [("rvalue", _("Security Model:"), "smbSecurity", security),
			("svalue", _("Domain:"), "smbWorkgroup", 0),
			("svalue", _("Domain Controllers:"), "smbServers", 0),
			("svalue", _("ADS Realm:"), "smbRealm", 0),
			("rvalue", _("Template Shell:"), "winbindTemplateShell", shells)]

		return self.getGenericChoices(_("Winbind Settings"),
			questions, _("Back"), next and _("Next") or _("Ok"),
			anothertxt=_("Join Domain"), anothercb=self.maybeGetJoinSettings)

	def getChoices(self):
		next = 1
		rc = False
		while next > 0 and next <= 6:
			self.info.update()
			if next == 1:
				rc = self.getMainChoices()
			elif next == 2:
				if self.info.enableIPAv2:
					more = (self.info.enableLDAP or
						self.info.enableLDAPAuth or
						self.info.enableKerberos or
						self.info.enableNIS or
						self.info.enableWinbind or
						self.info.enableWinbindAuth)
					rc = self.getIPAv2Settings(more)
			elif next == 3:
				if self.info.enableLDAP or self.info.enableLDAPAuth:
					more = (self.info.enableKerberos or
						self.info.enableNIS or
						self.info.enableWinbind or
						self.info.enableWinbindAuth)
					rc = self.getLDAPSettings(more)
			elif next == 4:
				if self.info.enableNIS:
					more = (self.info.enableKerberos or
						self.info.enableWinbind or
						self.info.enableWinbindAuth)
					rc = self.getNISSettings(more)
			elif next == 5:
				if self.info.enableKerberos:
					more = (self.info.enableWinbind or
						self.info.enableWinbindAuth)
					rc = self.getKerberosSettings(more)
			elif next == 6:
				if self.info.enableWinbind or self.info.enableWinbindAuth:
					more = False
					rc = self.getWinbindSettings(more)
			self.info.update()
			if rc:
				next += 1
			else:
				next -= 1
		return next == 7

	def displayCACertsMessage(self):
		text = (_("To connect to a LDAP server with TLS protocol enabled you need "
                        "a CA certificate which signed your server's certificate. "
                        "Copy the certificate in the PEM format to the '%s' directory.\n"
                        "Then press OK.") %
			self.info.ldapCacertDir)
		snack.ButtonChoiceWindow(self.screen, _("Warning"), text, [_("Ok")])

	def doUI(self):
		if self.options.kickstart:
			return True
		try:
			self.screen = snack.SnackScreen()
			packageversion = self.module() # FIXME - version

			self.screen.pushHelpLine(_(" <Tab>/<Alt-Tab> between elements   |   <Space> selects   |  <F12> next screen"))
			self.screen.drawRootText(0, 0, packageversion + " - (c) 1999-2005 Red Hat, Inc.")
			if not self.getChoices():
				# cancelled
				self.screen.finish()
				return False

			if self.info.enableLDAPS and self.info.testLDAPCACerts():
				self.displayCACertsMessage()
		finally:
			self.screen.finish()
		return True

if __name__ == '__main__':
	signal.signal(signal.SIGINT, signal.SIG_DFL)
	gettext.textdomain("authconfig")
	if runsAs("authconfig-tui"):
		# deprecated TUI
		module = AuthconfigTUI()
	else:
		module = Authconfig()
	sys.exit(module.run())
