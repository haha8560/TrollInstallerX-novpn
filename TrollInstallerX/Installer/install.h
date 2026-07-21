//
//  install.h
//  TrollInstallerX
//
//  Created by Alfie on 22/03/2024.
//

#ifndef install_h
#define install_h

NSString *find_path_for_app(NSString *appName);
bool install_trollstore(NSString *tar);
bool install_persistence_helper(NSString *app);
bool install_persistence_helper_with_paths(NSString *app, NSString *persistenceHelperPath, NSString *helperPath);

#endif /* install_h */
