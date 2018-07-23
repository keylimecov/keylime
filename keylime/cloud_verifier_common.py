#!/usr/bin/python

'''
DISTRIBUTION STATEMENT A. Approved for public release: distribution unlimited.

This material is based upon work supported by the Assistant Secretary of Defense for 
Research and Engineering under Air Force Contract No. FA8721-05-C-0002 and/or 
FA8702-15-D-0001. Any opinions, findings, conclusions or recommendations expressed in this
material are those of the author(s) and do not necessarily reflect the views of the 
Assistant Secretary of Defense for Research and Engineering.

Copyright 2015 Massachusetts Institute of Technology.

The software/firmware is provided to you on an As-Is basis

Delivered to the US Government with Unlimited Rights, as defined in DFARS Part 
252.227-7013 or 7014 (Feb 2014). Notwithstanding any copyright notice, U.S. Government 
rights in this work are defined by DFARS 252.227-7013 or DFARS 252.227-7014 as detailed 
above. Use of this work other than as specifically authorized by the U.S. Government may 
violate any copyrights that exist in this work.
'''

from urlparse import urlparse
import json
import base64
import time
import common
import registrar_client
import tpm_quote
import tpm_initialize
import os
import crypto
import ssl
import socket
import ca_util
import sqlite3
import revocation_notifier
import keylime_sqlite
import ConfigParser

logger = common.init_logging('cloudverifier_common')

config = ConfigParser.SafeConfigParser()
config.read(common.CONFIG_FILE)

class CloudInstance_Operational_State:
    REGISTERED = 0
    START = 1
    SAVED = 2
    GET_QUOTE = 3
    GET_QUOTE_RETRY = 4
    PROVIDE_V = 5
    PROVIDE_V_RETRY = 6 
    FAILED = 7
    TERMINATED = 8   
    INVALID_QUOTE = 9
    TENANT_FAILED = 10
    
    STR_MAPPINGS = {
        0 : "Registered",
        1 : "Start",
        2 : "Saved",
        3 : "Get Quote",
        4 : "Get Quote (retry)",
        5 : "Provide V",
        6 : "Provide V (retry)",
        7 : "Failed",
        8 : "Terminated",
        9 : "Invalid Quote",
        10 : "Tenant Quote Failed"
    }
    

class Timer(object):
    def __init__(self, verbose=False):
        self.verbose = verbose

    def __enter__(self):
        self.start = time.time()
        return self

    def __exit__(self, *args):
        self.end = time.time()
        self.secs = self.end - self.start
        self.msecs = self.secs * 1000  # millisecs
        if self.verbose:
            print 'elapsed time: %f ms' % self.msecs
            
def init_mtls(section='cloud_verifier',generatedir='cv_ca'):
    if not config.getboolean('general',"enable_tls"):
        logger.warning("TLS is currently disabled, keys will be sent in the clear! Should only be used for testing.")
        return None
    
    logger.info("Setting up TLS...")
    my_cert = config.get(section, 'my_cert')
    ca_cert = config.get(section, 'ca_cert')
    my_priv_key = config.get(section, 'private_key')
    my_key_pw = config.get(section,'private_key_pw')
    tls_dir = config.get(section,'tls_dir')

    if tls_dir =='generate':
        if my_cert!='default' or my_priv_key !='default' or ca_cert !='default':
            raise Exception("To use tls_dir=generate, options ca_cert, my_cert, and private_key must all be set to 'default'")
        
        if generatedir[0]!='/':
            generatedir =os.path.abspath('%s/%s'%(common.WORK_DIR,generatedir))
        tls_dir = generatedir
        ca_path = "%s/cacert.crt"%(tls_dir)
        if os.path.exists(ca_path):
            logger.info("Existing CA certificate found in %s, not generating a new one"%(tls_dir))
        else:    
            logger.info("Generating a new CA in %s and a client certificate for connecting"%tls_dir)
            logger.info("use keylime_ca -d %s to manage this CA"%tls_dir)
            if not os.path.exists(tls_dir):
                os.makedirs(tls_dir,0o700)
            if my_key_pw=='default':
                logger.warning("CAUTION: using default password for CA, please set private_key_pw to a strong password")
            ca_util.setpassword(my_key_pw)
            ca_util.cmd_init(tls_dir)
            ca_util.cmd_mkcert(tls_dir, socket.gethostname())
            ca_util.cmd_mkcert(tls_dir, 'client')
    
    if tls_dir == 'CV':
        if section !='registrar':
            raise Exception("You only use the CV option to tls_dir for the registrar not %s"%section)
        tls_dir = os.path.abspath('%s/%s'%(common.WORK_DIR,'cv_ca'))
        if not os.path.exists("%s/cacert.crt"%(tls_dir)):
            raise Exception("It appears that the verifier has not yet created a CA and certificates, please run the verifier first")

    # if it is relative path, convert to absolute in WORK_DIR
    if tls_dir[0]!='/':
        tls_dir = os.path.abspath('%s/%s'%(common.WORK_DIR,tls_dir))
            
    if ca_cert == 'default':
        ca_path = "%s/cacert.crt"%(tls_dir)
    else:
        ca_path = "%s/%s"%(tls_dir,ca_cert)

    if my_cert=='default':
        my_cert = "%s/%s-cert.crt"%(tls_dir,socket.gethostname())
    else:
        my_cert = "%s/%s"%(tls_dir,my_cert)
        
    if my_priv_key=='default':
        my_priv_key = "%s/%s-private.pem"%(tls_dir,socket.gethostname())
    else:
        my_priv_key = "%s/%s"%(tls_dir,my_priv_key)
        
    context = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
    context.load_verify_locations(cafile=ca_path)
    context.load_cert_chain(certfile=my_cert,keyfile=my_priv_key,password=my_key_pw)
    context.verify_mode = ssl.CERT_REQUIRED
    return context

def process_quote_response(instance, json_response):
    """Validates the response from the Cloud node.
    
    This method invokes an Registrar Server call to register, and then check the quote. 
    """
    received_public_key = None
    quote = None
    
    # in case of failure in response content do not continue
    try:
        received_public_key = json_response.get("pubkey",None)
        quote = json_response["quote"]
        
        ima_measurement_list = json_response.get("ima_measurement_list",None)
        
        logger.debug("received quote:      %s"%quote)
        logger.debug("for nonce:           %s"%instance['nonce'])
        logger.debug("received public key: %s"%received_public_key)
        logger.debug("received ima_measurement_list    %s"%(ima_measurement_list!=None))
    except Exception:
        return None
    
    # if no public key provided, then ensure we have cached it
    if received_public_key is None:
        if instance.get('public_key',"") == "" or instance.get('b64_encrypted_V',"")=="":
            logger.error("node did not provide public key and no key or encrypted_v was cached at CV")
            return False
        instance['provide_V'] = False
        received_public_key = instance['public_key']
    
    if instance.get('registrar_keys',"") is "":
        registrar_client.init_client_tls(config,'cloud_verifier')
        registrar_keys = registrar_client.getKeys(config.get("general","registrar_ip"),config.get("general","registrar_tls_port"),instance['instance_id'])
        if registrar_keys is None:
            logger.warning("AIK not found in registrar, quote not validated")
            return False
        instance['registrar_keys']  = registrar_keys
        
    if tpm_quote.is_deep_quote(quote):
        validQuote = tpm_quote.check_deep_quote(instance['nonce'],
                                                received_public_key,
                                                quote,
                                                instance['registrar_keys']['aik'],
                                                instance['registrar_keys']['provider_keys']['aik'],
                                                instance['vtpm_policy'],
                                                instance['tpm_policy'],
                                                ima_measurement_list,
                                                instance['ima_whitelist'])
    else:
        validQuote = tpm_quote.check_quote(instance['nonce'],
                                           received_public_key,
                                           quote,
                                           instance['registrar_keys']['aik'],
                                           instance['tpm_policy'],
                                           ima_measurement_list,
                                           instance['ima_whitelist'])
    if not validQuote:
        return False
    
    # set a flag so that we know that the node was verified once.
    # we only issue notifications for nodes that were at some point good
    instance['first_verified']=True
    
    # has public key changed? if so, clear out b64_encrypted_V, it is no longer valid
    if received_public_key != instance.get('public_key',""):
        instance['public_key'] = received_public_key
        instance['b64_encrypted_V'] = ""
        instance['provide_V'] = True
    
    # ok we're done
    return validQuote


def prepare_v(instance):
    # be very careful printing K, U, or V as they leak in logs stored on unprotected disks
    if common.INSECURE_DEBUG:
        logger.debug("b64_V (non encrypted): " + instance['v'])
        
    if instance.get('b64_encrypted_V',"") !="":
        b64_encrypted_V = instance['b64_encrypted_V']
        logger.debug("Re-using cached encrypted V")
    else:
        # encrypt V with the public key
        b64_encrypted_V = base64.b64encode(crypto.rsa_encrypt(crypto.rsa_import_pubkey(instance['public_key']),str(base64.b64decode(instance['v']))))
        instance['b64_encrypted_V'] = b64_encrypted_V
        
    logger.debug("b64_encrypted_V:" + b64_encrypted_V)
    post_data = {
              'encrypted_key': b64_encrypted_V
            }
    v_json_message = json.dumps(post_data)
    return v_json_message
    
def prepare_get_quote(instance):
    """This method encapsulates the action required to invoke a quote request on the Cloud Node.
    
    This method is part of the polling loop of the thread launched on Tenant POST. 
    """
    instance['nonce'] = tpm_initialize.random_password(20)
    
    params = {
        'nonce': instance['nonce'],
        'mask': instance['tpm_policy']['mask'],
        'vmask': instance['vtpm_policy']['mask'],
        }
    
    return params

def process_get_status(instance):
    if isinstance(instance['ima_whitelist'],dict) and 'whitelist' in instance['ima_whitelist']:
        wl_len = len(instance['ima_whitelist']['whitelist'])
    else:
        wl_len = 0
    response = {'operational_state':instance['operational_state'],
                'v':instance['v'],
                'ip':instance['ip'],
                'port':instance['port'],
                'tpm_policy':instance['tpm_policy'],
                'vtpm_policy':instance['vtpm_policy'],
                'metadata':instance['metadata'],
                'ima_whitelist_len':wl_len,
                }
    return response  

def get_query_tag_value(path, query_tag):
    """This is a utility method to query for specific the http parameters in the uri.  
    
    Returns the value of the parameter, or None if not found."""  
    data = { }
    parsed_path = urlparse(path)
    query_tokens = parsed_path.query.split('&')
    # find the 'ids' query, there can only be one
    for tok in query_tokens:
        query_tok = tok.split('=')
        query_key = query_tok[0]
        if query_key is not None and query_key == query_tag:
            # ids tag contains a comma delimited list of ids
            data[query_tag] = query_tok[1]    
            break        
    return data.get(query_tag,None) 

# sign a message with revocation key.  telling of verification problem
def notifyError(instance,msgtype='revocation'):
    if not config.getboolean('cloud_verifier', 'revocation_notifier'):
        return

    # prepare the revocation message:
    revocation = {
                'type':msgtype,
                'ip':instance['ip'],
                'port':instance['port'],
                'tpm_policy':instance['tpm_policy'],
                'vtpm_policy':instance['vtpm_policy'],
                'metadata':instance['metadata'],
                } 
    
    revocation['event_time'] = time.asctime()
    tosend={'msg': json.dumps(revocation)}
            
    #also need to load up private key for signing revocations
    if instance['revocation_key']!="":
        global signing_key
        signing_key = crypto.rsa_import_privkey(instance['revocation_key'])
        tosend['signature']=crypto.rsa_sign(signing_key,tosend['msg'])
        
        #print "verified? %s"%crypto.rsa_verify(signing_key, tosend['signature'], tosend['revocation'])
    else:
        tosend['siganture']="none"
            
    revocation_notifier.notify(tosend)

# ===== sqlite stuff =====
def init_db(db_filename):
    # in the form key, SQL type
    cols_db = {
        'instance_id': 'TEXT PRIMARY_KEY',
        'v': 'TEXT',
        'ip': 'TEXT',
        'port': 'INT',
        'operational_state': 'INT',
        'public_key': 'TEXT',
        'tpm_policy' : 'TEXT', 
        'vtpm_policy' : 'TEXT', 
        'metadata' : 'TEXT',
        'ima_whitelist' : 'TEXT',
        'revocation_key': 'TEXT',
        }
    
    # these are the columns that contain json data and need marshalling
    json_cols_db = ['tpm_policy','vtpm_policy','metadata','ima_whitelist']
    
    # in the form key : default value
    exclude_db = {
        'registrar_keys': '',
        'nonce': '',
        'b64_encrypted_V': '',
        'provide_V': True,
        'num_retries': 0,
        'pending_event': None,
        'first_verified':False,
        }
    return keylime_sqlite.KeylimeDB(db_filename,cols_db,json_cols_db,exclude_db)

